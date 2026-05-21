import Vision
import CoreImage
import AVFoundation
import UIKit
import Observation

struct DetectedPerson {
    let boundingBox: CGRect
    let id: UUID
    let name: String // Имя из базы или "Не определен"
    let confidence: Float
}

// Перечисление фонов оставляем без изменений...
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
        case .forest: return "forest"
        case .city: return "city"
        case .office: return "office"
        case .none: return ""
        }
    }
}

@Observable
class BackgroundReplacementProcessor: NSObject {
    private let visionQueue = DispatchQueue(label: "com.processor.vision", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    private var currentBackgroundType: BackgroundType = .none
    
    // Сюда загружается наша CoreML модель распознавания лиц
    private var faceClassifierModel: VNCoreMLModel?
    
    @ObservationIgnored
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    
    // Вместо просто прямоугольников людей теперь ищем лица
    @ObservationIgnored
    private let faceDetectionRequest: VNDetectFaceRectanglesRequest
    
    var onProcessedFrame: ((UIImage, [DetectedPerson]) -> Void)?
    var onSegmentedFrame: ((UIImage) -> Void)?
    var onPeopleCountUpdated: ((Int) -> Void)?
    var onBackgroundTypeChanged: ((BackgroundType) -> Void)?
    
    override init() {
        // 1. Сегментация
        let segReq = VNGeneratePersonSegmentationRequest()
        segReq.qualityLevel = .balanced
        segReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.segmentationRequest = segReq
        
        // 2. Детекция лиц
        self.faceDetectionRequest = VNDetectFaceRectanglesRequest()
        
        super.init()
        
        // 3. Инициализация нейронки распознавания лиц
        setupFaceClassifier()
    }
    
    private func setupFaceClassifier() {
        // MyFaceClassifier — это имя твоей mlmodel, которую ты закинешь в проект.
        // Если компилятор ругается, пока не добавил модель, можно закомментировать этот блок.
        guard let modelURL = Bundle.main.url(forResource: "MyFaceClassifier", withExtension: "mlmodelc"),
              let coreMLModel = try? MLModel(contentsOf: modelURL),
              let visionModel = try? VNCoreMLModel(for: coreMLModel) else {
            print("⚠️ Не удалось загрузить модель MyFaceClassifier.mlmodel. Будет использоваться режим без идентификации.")
            return
        }
        self.faceClassifierModel = visionModel
    }
    
    func setBackgroundType(_ type: BackgroundType) {
        currentBackgroundType = type
        onBackgroundTypeChanged?(type)
    }
    
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        visionQueue.async { [weak self] in
            self?.performDetectionAndIdentification(pixelBuffer)
        }
    }
    
    private func performDetectionAndIdentification(_ pixelBuffer: CVPixelBuffer) {
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
            var requests: [VNRequest] = [faceDetectionRequest]
            if currentBackgroundType != .none {
                requests.append(segmentationRequest)
            }
            
            try handler.perform(requests)
            
            let faceObservations = faceDetectionRequest.results ?? []
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            // Запускаем идентификацию для каждого найденного лица
            let detectedPeople = identifyFaces(faceObservations, in: pixelBuffer, ciImage: ciImage)
            
            // --- Отрисовка и кадрирование ---
            if currentBackgroundType != .none,
               let maskPixelBuffer = segmentationRequest.results?.first?.pixelBuffer {
                let segmented = createSegmentedImage(from: ciImage, mask: maskPixelBuffer)
                let annotated = drawBoundingBoxes(segmented, people: detectedPeople)
                
                DispatchQueue.main.async {
                    self.onSegmentedFrame?(annotated)
                    self.onProcessedFrame?(annotated, detectedPeople)
                    self.onPeopleCountUpdated?(detectedPeople.count)
                }
            } else {
                let originalImage = UIImage(ciImage: ciImage)
                let annotated = drawBoundingBoxes(originalImage, people: detectedPeople)
                
                DispatchQueue.main.async {
                    self.onProcessedFrame?(annotated, detectedPeople)
                    self.onSegmentedFrame?(annotated)
                    self.onPeopleCountUpdated?(detectedPeople.count)
                }
            }
        } catch {
            print("Ошибка обработки: \(error)")
        }
    }
    
    // MARK: - Идентификация лиц с помощью CoreML
    private func identifyFaces(_ observations: [VNFaceObservation], in pixelBuffer: CVPixelBuffer, ciImage: CIImage) -> [DetectedPerson] {
        var results: [DetectedPerson] = []
        
        // Получаем реальные пиксельные размеры кадра
        let imageSize = ciImage.extent.size
        
        for observation in observations {
            let bbox = observation.boundingBox
            var detectedName = "Не определен"
            var confidence: Float = Float(observation.confidence)
            
            if let classifier = faceClassifierModel {
                // Переводим нормализованные координаты Vision (0..1) в реальные пиксели CIImage
                // Vision считает Y снизу вверх, поэтому используем правильную трансформацию
                let x = bbox.minX * imageSize.width
                let y = bbox.minY * imageSize.height
                let width = bbox.width * imageSize.width
                let height = bbox.height * imageSize.height
                
                let cropRect = CGRect(x: x, y: y, width: width, height: height)
                
                // Вырезаем лицо из кадра
                let croppedCIImage = ciImage.cropped(to: cropRect)
                
                // Создаем запрос к нашей CoreML модели
                let faceClassificationRequest = VNCoreMLRequest(model: classifier) { request, error in
                    guard let classificationResults = request.results as? [VNClassificationObservation],
                          let topResult = classificationResults.first else { return }
                    
                    // Выводим в консоль для отладки, что именно видит модель
                    print("Модель видит: \(topResult.identifier) с уверенностью \(topResult.confidence * 100)%")
                    
                    // Если нейросеть уверена больше чем на 65% и это не папка "Unknown"
                    if topResult.confidence > 0.25 && topResult.identifier != "Unknown" {
                        // Заменяем нижние подчеркивания на пробелы для красивого отображения
                        detectedName = topResult.identifier.replacingOccurrences(of: "_", with: " ")
                        confidence = topResult.confidence
                    } else {
                        detectedName = "Не определен"
                    }
                }
                
                // Отключаем автоматический поворот, так как мы уже вырезали под нужную ориентацию
                faceClassificationRequest.imageCropAndScaleOption = .scaleFill
                
                let handler = VNImageRequestHandler(ciImage: croppedCIImage, options: [:])
                try? handler.perform([faceClassificationRequest])
            }
            
            let person = DetectedPerson(
                boundingBox: bbox,
                id: UUID(),
                name: detectedName,
                confidence: confidence
            )
            results.append(person)
        }
        
        return results
    }
    
    private func createSegmentedImage(from cameraImage: CIImage, mask maskBuffer: CVPixelBuffer) -> UIImage {
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let scaleX = cameraImage.extent.width / maskImage.extent.width
        let scaleY = cameraImage.extent.height / maskImage.extent.height
        let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        let blendFilter = CIFilter(name: "CIBlendWithMask")!
        blendFilter.setValue(cameraImage, forKey: kCIInputImageKey)
        blendFilter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        
        guard let outputImage = blendFilter.outputImage else { return UIImage(ciImage: cameraImage) }
        
        if let cgImage = ciContext.createCGImage(outputImage, from: cameraImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(ciImage: outputImage)
    }
    
    // MARK: - Рендеринг рамок и Имен
    private func drawBoundingBoxes(_ image: UIImage, people: [DetectedPerson]) -> UIImage {
        guard !people.isEmpty else { return image }
        
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            image.draw(at: .zero)
            
            for person in people {
                let bbox = person.boundingBox
                
                let x = bbox.minX * image.size.width
                let y = (1 - bbox.maxY) * image.size.height
                let width = bbox.width * image.size.width
                let height = bbox.height * image.size.height
                
                let rect = CGRect(x: x, y: y, width: width, height: height)
                
                // Цвет: бирюзовый для распознанных, красный для неопределенных
                let isIdentified = person.name != "Не определен"
                let strokeColor = isIdentified ? UIColor.green : UIColor.red
                
                context.cgContext.setStrokeColor(strokeColor.cgColor)
                context.cgContext.setLineWidth(4)
                context.cgContext.stroke(rect)
                
                // Текст надписи
                let labelText = isIdentified ? person.name : "ID: Не определен"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 16, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                
                let textSize = labelText.size(withAttributes: attributes)
                let labelRect = CGRect(x: x, y: max(0, y - textSize.height - 8), width: textSize.width + 12, height: textSize.height + 8)
                
                strokeColor.withAlphaComponent(0.85).setFill()
                UIBezierPath(roundedRect: labelRect, cornerRadius: 6).fill()
                
                let textRect = CGRect(x: x + 6, y: max(4, y - textSize.height - 4), width: textSize.width, height: textSize.height)
                labelText.draw(in: textRect, withAttributes: attributes)
            }
        }
    }
}
