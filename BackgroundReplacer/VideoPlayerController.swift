import UIKit
import AVFoundation

class VideoPlayerController: UIViewController {
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var playerLooper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var currentVideoName: String?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }
    
    func playVideo(named videoName: String) {
        // Avoid re-creating player if already playing the same video
        guard videoName != currentVideoName else { return }
        currentVideoName = videoName
        
        guard !videoName.isEmpty else {
            cleanupPlayer()
            return
        }
        
        guard let videoURL = Bundle.main.url(forResource: videoName, withExtension: "mp4") else {
            print("❌ Video not found: \(videoName)")
            return
        }
        
        // Clean up previous player
        cleanupPlayer()
        
        // Use AVQueuePlayer + AVPlayerLooper for seamless looping
        let asset = AVAsset(url: videoURL)
        let templateItem = AVPlayerItem(asset: asset)
        
        let queue = AVQueuePlayer(items: [templateItem])
        queue.isMuted = true
        self.queuePlayer = queue
        self.player = queue
        
        // AVPlayerLooper handles seamless looping
        self.playerLooper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: asset))
        
        // Setup layer
        let layer = AVPlayerLayer(player: queue)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        self.playerLayer = layer
        
        queue.play()
    }
    
    private func cleanupPlayer() {
        player?.pause()
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer = nil
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = view.bounds
    }
    
    deinit {
        cleanupPlayer()
    }
}
