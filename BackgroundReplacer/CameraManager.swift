import AVFoundation
import Observation

@Observable
class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var isAuthorized = false
    var errorMessage: String?
    var isFrontCamera = true
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.cameramanager.processing", qos: .userInitiated)
    
    var onFrameCapture: ((CVPixelBuffer, CMTime) -> Void)?
    private var frameSkipCounter = 0
    // Process every 2nd frame to keep things smooth while still responsive
    private let frameSkipInterval = 1
    
    override init() {
        super.init()
        requestCameraPermission()
    }
    
    func startSession() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }
    
    func stopSession() {
        processingQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }
    
    func switchCamera() {
        isFrontCamera.toggle()
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.stopRunning()
            self.captureSession.beginConfiguration()
            self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
            self.addCameraInput()
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
        }
    }
    
    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                if granted {
                    self?.setupCaptureSession()
                } else {
                    self?.errorMessage = "Camera access denied"
                }
            }
        }
    }
    
    private func setupCaptureSession() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            #if targetEnvironment(simulator)
            DispatchQueue.main.async {
                self.errorMessage = "Camera not available in simulator"
            }
            return
            #endif
            
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high
            
            self.addCameraInput()
            
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
                self.videoOutput.setSampleBufferDelegate(self, queue: self.processingQueue)
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                // Drop late frames to avoid backpressure
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
            }
            
            self.captureSession.commitConfiguration()
            
            if let connection = self.videoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                // Mirror front camera
                if self.isFrontCamera && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
            
            DispatchQueue.main.async {
                self.errorMessage = nil
            }
        }
    }
    
    private func addCameraInput() {
        let position: AVCaptureDevice.Position = self.isFrontCamera ? .front : .back
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            DispatchQueue.main.async {
                self.errorMessage = "Camera not available"
            }
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }
            
            // Update mirroring for the new camera
            if let connection = self.videoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                if self.isFrontCamera && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to setup camera: \(error.localizedDescription)"
            }
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Frame skipping to reduce load
        frameSkipCounter += 1
        if frameSkipCounter <= frameSkipInterval {
            return
        }
        frameSkipCounter = 0
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        onFrameCapture?(pixelBuffer, timestamp)
    }
}
