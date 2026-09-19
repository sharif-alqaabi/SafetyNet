import AVFoundation
import Combine
import SwiftUI
import UIKit

final class CameraRearService: NSObject, ObservableObject {
    @Published @MainActor private(set) var isRunning = false
    @Published @MainActor private(set) var lastJPEG: Data?
    @Published @MainActor var errorMessage: String?

    let session = AVCaptureSession()
    let clipBuffer = ClipRingBuffer(window: 16)

    private let sessionQueue = DispatchQueue(label: "fallguard.camera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let pixelLock = NSLock()
    private var _latestPixelBuffer: CVPixelBuffer?
    private var _jpegPaused = false

    private var latestPixelBuffer: CVPixelBuffer? {
        get {
            pixelLock.lock(); defer { pixelLock.unlock() }
            return _latestPixelBuffer
        }
        set {
            pixelLock.lock(); _latestPixelBuffer = newValue; pixelLock.unlock()
        }
    }
    private var frameTimer: Timer?
    private var jpegInterval: TimeInterval = 0.2
    var onJPEG: ((Data) -> Void)?

    private var jpegPaused: Bool {
        get { pixelLock.lock(); defer { pixelLock.unlock() }; return _jpegPaused }
        set { pixelLock.lock(); _jpegPaused = newValue; pixelLock.unlock() }
    }

    @MainActor
    func setJPEGInterval(_ interval: TimeInterval) {
        jpegInterval = max(0.1, interval)
        if isRunning, !jpegPaused { startJPEGTimer() }
    }

    @MainActor
    func pauseJPEG() {
        jpegPaused = true
        frameTimer?.invalidate()
        frameTimer = nil
    }

    @MainActor
    func resumeJPEG() {
        jpegPaused = false
        if isRunning { startJPEGTimer() }
    }

    @MainActor
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.configureAndStart() }
                    else { self?.errorMessage = "Camera permission denied" }
                }
            }
        default:
            errorMessage = "Camera permission denied"
        }
    }

    @MainActor
    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        isRunning = false
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.automaticallyConfiguresApplicationAudioSession = false
            self.session.sessionPreset = .hd1280x720
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                Task { @MainActor in self.errorMessage = "Rear camera unavailable" }
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(input)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            if let connection = self.videoOutput.connection(with: .video) {
                connection.isVideoMirrored = false
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            Task { @MainActor in
                self.isRunning = true
                if !self.jpegPaused { self.startJPEGTimer() }
            }
        }
    }

    @MainActor
    private func startJPEGTimer() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: jpegInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureJPEG() }
        }
    }

    private func captureJPEG() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.jpegPaused { return }
            guard let pixel = self.latestPixelBuffer else { return }
            guard let jpeg = Self.jpegData(from: pixel, maxWidth: 768) else { return }
            self.clipBuffer.append(jpeg)
            Task { @MainActor in
                self.lastJPEG = jpeg
                self.onJPEG?(jpeg)
            }
        }
    }

    private static func jpegData(from pixelBuffer: CVPixelBuffer, maxWidth: CGFloat) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        let scale = min(1, maxWidth / max(extent.width, 1))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.55)
    }
}

extension CameraRearService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestPixelBuffer = pixel
    }
}

struct RearPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
