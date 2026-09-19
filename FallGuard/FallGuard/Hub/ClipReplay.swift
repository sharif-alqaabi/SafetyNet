import AVFoundation
import CoreImage
import Foundation
import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class ClipReplay: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentImage: UIImage?
    @Published private(set) var playhead: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    var onJPEG: ((Data) -> Void)?

    let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        return player
    }()

    /// Skip the warning card so Gemini watches the room in real time.
    private let actionStart: TimeInterval = 5
    private var playTask: Task<Void, Never>?
    private var videoOutput: AVPlayerItemVideoOutput?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "TestClip", withExtension: "mp4")
    }

    var clockLabel: String {
        let now = max(0, Int(playhead.rounded(.down)))
        let total = max(0, Int((duration - actionStart).rounded(.down)))
        return String(format: "LIVE CLIP %d:%02d / %d:%02d", now / 60, now % 60, total / 60, total % 60)
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        isPlaying = false
        playhead = 0
        currentImage = nil
    }

    /// Demo: stop advancing the clip and sending frames to Gemini after the fall.
    func freezeAtFall() {
        playTask?.cancel()
        playTask = nil
        player.pause()
        isPlaying = false
        print("[Clip] frozen at fall t=\(playhead)s")
    }

    func playBundledClip(step: TimeInterval = 0.2) async {
        stop()
        guard let url = Self.bundledURL else { return }
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)
        videoOutput = output
        player.replaceCurrentItem(with: item)
        do {
            duration = try await item.asset.load(.duration).seconds
        } catch {
            duration = 60
        }
        playhead = 0
        isPlaying = true
        let start = CMTime(seconds: actionStart, preferredTimescale: 600)
        await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        print("[Clip] live play from \(actionStart)s of \(duration)s")
        playTask = Task { await pump(step: step) }
        await playTask?.value
        if !Task.isCancelled { isPlaying = false }
    }

    private func pump(step: TimeInterval) async {
        var sent = 0
        while !Task.isCancelled {
            let time = player.currentTime()
            let seconds = time.seconds
            if seconds.isFinite {
                playhead = max(0, seconds - actionStart)
            }
            if player.timeControlStatus == .paused, playhead > 0.4 {
                break
            }
            if duration > actionStart, seconds >= duration - 0.05 {
                break
            }
            if let frame = copyFrame(at: time) {
                sent += 1
                currentImage = frame.image
                if sent == 1 || sent % 15 == 0 {
                    print("[Clip] live frames=\(sent) t=\(String(format: "%.1f", playhead))s")
                }
                onJPEG?(frame.jpeg)
            }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
        player.pause()
        print("[Clip] live done sent=\(sent) t=\(playhead)s")
    }

    private func copyFrame(at time: CMTime) -> (image: UIImage, jpeg: Data)? {
        guard let output = videoOutput else { return nil }
        let host = output.itemTime(forHostTime: CACurrentMediaTime())
        let stamp = host.isValid ? host : time
        guard let buffer = output.copyPixelBuffer(forItemTime: stamp, itemTimeForDisplay: nil) else {
            return nil
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        let image = UIImage(cgImage: cg)
        guard let jpeg = image.jpegData(compressionQuality: 0.55) else { return nil }
        return (image, jpeg)
    }
}

struct ClipPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
