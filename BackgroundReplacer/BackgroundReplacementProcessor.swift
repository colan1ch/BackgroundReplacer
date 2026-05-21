import Vision
import CoreImage
import AVFoundation
import UIKit
import Observation

struct DetectedPerson {
    let boundingBox: CGRect
    let id: UUID
    let confidence: Float
}

enum BackgroundType: String, CaseIterable {
    case none = "Без фона"
    case forest = "Лес"
    case city = "Город"
    case office = "Офис"
    
    var id: String { self.rawValue }
}

extension BackgroundType {
    var videoFileName: String {
        switch self {
        case .forest:
            return "forest"
        case .city:
            return "city"
        case .office:
            return "office"
        case .none:
            return ""
        }
    }
}

@Observable
class BackgroundReplacementProcessor: NSObject {
    private let visionQueue = DispatchQueue(label: "com.processor.vision", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    private var currentBackgroundType: BackgroundType = .none
    
    // Tracking state
    private var trackedPeople: [UUID: (person: DetectedPerson, framesSinceSeen: Int)] = [:]
    
    // Segmentation request — reuse for performance
    @ObservationIgnored
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    
    // Detection request
    @ObservationIgnored
    private let detectionRequest: VNDetectHumanRectanglesRequest
    
    // Callbacks
    var onProcessedFrame: ((UIImage, [DetectedPerson]) -> Void)?
    var onSegmentedFrame: ((UIImage) -> Void)?
    var onPeopleCountUpdated: ((Int) -> Void)?
    var onBackgroundTypeChanged: ((BackgroundType) -> Void)?
    
    override init() {
        let segReq = VNGeneratePersonSegmentationRequest()
        segReq.qualityLevel = .balanced
        segReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.segmentationRequest = segReq
        
        let detReq = VNDetectHumanRectanglesRequest()
        detReq.upperBodyOnly = false
        self.detectionRequest = detReq
        
        super.init()
    }
    
    func setBackgroundType(_ type: BackgroundType) {
        currentBackgroundType = type
        print("🟢 [BACKGROUND CHANGED] Фон изменён на: \(type.rawValue)")
        onBackgroundTypeChanged?(type)
    }
    
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        visionQueue.async { [weak self] in
            self?.performDetection(pixelBuffer)
        }
    }
    
    // MARK: - Detection & Segmentation
    
    private func performDetection(_ pixelBuffer: CVPixelBuffer) {
        #if targetEnvironment(simulator)
        let uiImage = UIImage(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
        DispatchQueue.main.async {
            self.onProcessedFrame?(uiImage, [])
            self.onSegmentedFrame?(uiImage)
            self.onPeopleCountUpdated?(0)
        }
        return
        #endif
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            // Run both requests together for efficiency
            var requests: [VNRequest] = [detectionRequest]
            if currentBackgroundType != .none {
                requests.append(segmentationRequest)
            }
            
            try handler.perform(requests)
            
            // --- Person detection & tracking ---
            let observations = detectionRequest.results ?? []
            let detectedPeople = self.trackPeople(observations)
            let peopleIDs = detectedPeople.map { $0.id.uuidString.prefix(6) }.joined(separator: ", ")
            print("👤 [PERSON DETECTION] Обнаружено людей: \(detectedPeople.count) | ID: [\(peopleIDs)]")
            
            // --- Segmentation (background replacement) ---
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            if currentBackgroundType != .none,
               let maskPixelBuffer = segmentationRequest.results?.first?.pixelBuffer {
                // Create segmented image (person only, transparent background)
                let segmented = createSegmentedImage(from: ciImage, mask: maskPixelBuffer)
                let annotated = drawBoundingBoxesOnCIImage(segmented, people: detectedPeople)
                
                DispatchQueue.main.async {
                    self.onSegmentedFrame?(annotated)
                    self.onProcessedFrame?(annotated, detectedPeople)
                    self.onPeopleCountUpdated?(detectedPeople.count)
                }
            } else {
                // No background replacement — just draw bounding boxes on the original frame
                let originalImage = UIImage(ciImage: ciImage)
                let annotated = drawBoundingBoxes(originalImage, people: detectedPeople)
                
                DispatchQueue.main.async {
                    self.onProcessedFrame?(annotated, detectedPeople)
                    self.onSegmentedFrame?(annotated)
                    self.onPeopleCountUpdated?(detectedPeople.count)
                }
            }
        } catch {
            print("Detection error: \(error)")
            let uiImage = UIImage(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
            DispatchQueue.main.async {
                self.onProcessedFrame?(uiImage, [])
                self.onSegmentedFrame?(uiImage)
                self.onPeopleCountUpdated?(0)
            }
        }
    }
    
    // MARK: - Segmentation
    
    private func createSegmentedImage(from cameraImage: CIImage, mask maskBuffer: CVPixelBuffer) -> UIImage {
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        
        // Scale mask to match camera image size
        let scaleX = cameraImage.extent.width / maskImage.extent.width
        let scaleY = cameraImage.extent.height / maskImage.extent.height
        let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // Apply mask: person = camera pixels, background = transparent
        let blendFilter = CIFilter(name: "CIBlendWithMask")!
        blendFilter.setValue(cameraImage, forKey: kCIInputImageKey)
        blendFilter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        
        guard let outputImage = blendFilter.outputImage else {
            return UIImage(ciImage: cameraImage)
        }
        
        // Render to CGImage for better performance
        if let cgImage = ciContext.createCGImage(outputImage, from: cameraImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        
        return UIImage(ciImage: outputImage)
    }
    
    // MARK: - Tracking
    
    private func trackPeople(_ observations: [VNHumanObservation]) -> [DetectedPerson] {
        var currentPeople: [DetectedPerson] = []
        var matchedIDs = Set<UUID>()
        
        for id in trackedPeople.keys {
            trackedPeople[id]?.framesSinceSeen += 1
        }
        
        for observation in observations {
            let bbox = observation.boundingBox
            var bestMatch: (id: UUID, distance: Float)? = nil
            
            for (id, data) in trackedPeople {
                guard !matchedIDs.contains(id) else { continue }
                let distance = calculateDistance(bbox, data.person.boundingBox)
                if distance < 0.15 {
                    if bestMatch == nil || distance < bestMatch!.distance {
                        bestMatch = (id, distance)
                    }
                }
            }
            
            let personID: UUID
            if let match = bestMatch {
                personID = match.id
                trackedPeople[personID]?.framesSinceSeen = 0
            } else {
                personID = UUID()
            }
            
            let person = DetectedPerson(
                boundingBox: bbox,
                id: personID,
                confidence: Float(observation.confidence)
            )
            currentPeople.append(person)
            trackedPeople[personID] = (person: person, framesSinceSeen: 0)
            matchedIDs.insert(personID)
        }
        
        // Remove stale tracks
        let keysToRemove = trackedPeople.keys.filter { !matchedIDs.contains($0) && trackedPeople[$0]!.framesSinceSeen > 5 }
        for key in keysToRemove {
            trackedPeople.removeValue(forKey: key)
        }
        
        return currentPeople
    }
    
    private func calculateDistance(_ bbox1: CGRect, _ bbox2: CGRect) -> Float {
        let center1 = CGPoint(x: bbox1.midX, y: bbox1.midY)
        let center2 = CGPoint(x: bbox2.midX, y: bbox2.midY)
        let dx = Float(center1.x - center2.x)
        let dy = Float(center1.y - center2.y)
        return sqrt(dx * dx + dy * dy)
    }
    
    // MARK: - Drawing Bounding Boxes
    
    private func drawBoundingBoxesOnCIImage(_ image: UIImage, people: [DetectedPerson]) -> UIImage {
        guard !people.isEmpty else { return image }
        return drawBoundingBoxes(image, people: people)
    }
    
    private func drawBoundingBoxes(_ image: UIImage, people: [DetectedPerson]) -> UIImage {
        guard !people.isEmpty else { return image }
        
        let renderer = UIGraphicsImageRenderer(size: image.size)
        
        return renderer.image { context in
            image.draw(at: .zero)
            
            let colors: [UIColor] = [
                UIColor(red: 0.0, green: 0.8, blue: 1.0, alpha: 1.0),  // cyan
                UIColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 1.0),  // green
                UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),  // yellow
                UIColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0),  // red
                UIColor(red: 0.7, green: 0.3, blue: 1.0, alpha: 1.0),  // purple
                UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0),  // orange
            ]
            
            for (index, person) in people.enumerated() {
                let bbox = person.boundingBox
                
                let x = bbox.minX * image.size.width
                let y = (1 - bbox.maxY) * image.size.height
                let width = bbox.width * image.size.width
                let height = bbox.height * image.size.height
                
                let rect = CGRect(x: x, y: y, width: width, height: height)
                
                let color = colors[index % colors.count]
                context.cgContext.setStrokeColor(color.cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.stroke(rect)
                
                // Label background
                let labelText = "ID:\(index + 1)"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let textSize = labelText.size(withAttributes: attributes)
                let labelRect = CGRect(x: x, y: max(0, y - textSize.height - 6), width: textSize.width + 12, height: textSize.height + 6)
                
                color.withAlphaComponent(0.8).setFill()
                UIBezierPath(roundedRect: labelRect, cornerRadius: 4).fill()
                
                let textRect = CGRect(
                    x: x + 6,
                    y: max(3, y - textSize.height - 3),
                    width: textSize.width,
                    height: textSize.height
                )
                labelText.draw(in: textRect, withAttributes: attributes)
            }
        }
    }
}
