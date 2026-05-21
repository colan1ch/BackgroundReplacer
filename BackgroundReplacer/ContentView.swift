import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var cameraManager = CameraManager()
    @State private var processor = BackgroundReplacementProcessor()
    
    @State private var currentFrame: UIImage?
    @State private var peopleCount = 0
    @State private var detectedPeople: [DetectedPerson] = []
    @State private var selectedBackground: BackgroundType = .none
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            // Фоновое видео — показывается только когда выбран фон
            if selectedBackground != .none {
                VideoPlayerWrapper(videoName: selectedBackground.videoFileName)
                    .ignoresSafeArea()
            }
            
            // Камера поверх видео (с прозрачным фоном если сегментация активна)
            if let frame = currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }
            
            // UI поверх всего
            VStack {
                // Верхняя панель
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Обнаружено людей:")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("\(peopleCount)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.cyan)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    
                    Spacer()
                    
                    Button(action: {
                        cameraManager.switchCamera()
                    }) {
                        Image(systemName: "camera.rotate.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // Нижняя панель — выбор фона
                VStack(spacing: 10) {
                    Text("Фон")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    
                    HStack(spacing: 8) {
                        ForEach(BackgroundType.allCases, id: \.id) { background in
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedBackground = background
                                    processor.setBackgroundType(background)
                                }
                            }) {
                                Text(background.rawValue)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        selectedBackground == background
                                            ? Color.cyan
                                            : Color.white.opacity(0.15)
                                    )
                                    .foregroundColor(
                                        selectedBackground == background
                                            ? .black
                                            : .white
                                    )
                                    .cornerRadius(10)
                            }
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            setupBindings()
            cameraManager.startSession()
            processor.setBackgroundType(.none)
        }
        .onDisappear {
            cameraManager.stopSession()
        }
    }
    
    private func setupBindings() {
        cameraManager.onFrameCapture = { pixelBuffer, timestamp in
            processor.processFrame(pixelBuffer, timestamp: timestamp)
        }
        
        processor.onProcessedFrame = { image, people in
            currentFrame = image
            detectedPeople = people
        }
        
        processor.onPeopleCountUpdated = { count in
            peopleCount = count
        }
    }
}

// MARK: - VideoPlayerWrapper

struct VideoPlayerWrapper: UIViewControllerRepresentable {
    let videoName: String
    
    func makeUIViewController(context: Context) -> VideoPlayerController {
        let controller = VideoPlayerController()
        controller.playVideo(named: videoName)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: VideoPlayerController, context: Context) {
        uiViewController.playVideo(named: videoName)
    }
}

#Preview {
    ContentView()
}