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
            
            // Камера поверх видео (с прозрачным фоном, если сегментация активна)
            if let frame = currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }
            
            // UI поверх всего
            VStack {
                // Верхняя панель с информацией об идентификации
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Статус идентификации:")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        if detectedPeople.isEmpty {
                            Text("В кадре никого нет")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundColor(.gray)
                        } else {
                            // Выводим список имен людей, которые сейчас находятся в кадре
                            ForEach(detectedPeople, id: \.id) { person in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(person.name != "Не определен" ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    
                                    Text(person.name != "Не определен" ? person.name : "Неизвестный пользователь")
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundColor(person.name != "Не определен" ? .green : .white)
                                    
                                    Text(String(format: "(%.0f%%)", person.confidence * 100))
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(14)
                    
                    Spacer()
                    
                    // Кнопка смены камеры
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
                
                // Нижняя панель — выбор интерактивного фона
                VStack(spacing: 10) {
                    Text("Интерактивный фон")
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
                                            ? Color.green // Поменяли на зеленый, так как это стандарт для хромакея / успешного распознавания
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
