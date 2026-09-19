import AVFoundation
import Combine

final class AudioIO: ObservableObject {
    @Published @MainActor var isArmed = false
    @Published @MainActor var lastError: String?

    var onPCM16k: ((Data) -> Void)?
    @Published @MainActor var inputLevel: Float = 0
    /// True while Gemini audio is still coming out of the speaker.
    @Published @MainActor var isPlayingBack = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let converterLock = NSLock()
    private var _converterTo16k: AVAudioConverter?
    private var converterTo16k: AVAudioConverter? {
        get { converterLock.lock(); defer { converterLock.unlock() }; return _converterTo16k }
        set { converterLock.lock(); _converterTo16k = newValue; converterLock.unlock() }
    }
    private var tapInstalled = false
    private var playerAttached = false
    private let playLock = NSLock()
    private var playbackUntil = Date.distantPast
    private var playbackWatchdog: Task<Void, Never>?

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(mic)
        }
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
    }

    func restart() throws {
        stop()
        try start()
    }

    func start() throws {
        try configureSession()
        if !playerAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            playerAttached = true
        }

        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            print("[Audio] voice processing off: \(error.localizedDescription)")
        }

        let hwFormat = input.outputFormat(forBus: 0)
        print("[Audio] hw \(hwFormat.sampleRate) Hz ch=\(hwFormat.channelCount)")
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            Task { @MainActor in self.lastError = "Mic format not ready — wait a moment and simulate a fall" }
            return
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        converterTo16k = AVAudioConverter(from: hwFormat, to: target)

        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer, target: target)
        }
        tapInstalled = true

        try engine.start()
        if !player.isPlaying { player.play() }
        Task { @MainActor in
            self.isArmed = true
            self.lastError = nil
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        Task { @MainActor in self.isArmed = false }
    }

    /// Requests mic permission, then starts capture for Live.
    func startWithPermission() async {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        await MainActor.run {
            if !granted {
                lastError = "Microphone permission denied — Live cannot hear you."
            }
        }
        guard granted else { return }
        do {
            try start()
        } catch {
            await MainActor.run {
                lastError = "Audio start failed: \(error.localizedDescription)"
            }
        }
    }

    func playTone() {
        let sampleRate = 24_000.0
        let duration = 0.35
        let n = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / Float(sampleRate)
            samples[i] = sin(2 * .pi * 660 * t) * 0.25
        }
        playFloat24k(samples)
    }

    func playPCM24k(_ data: Data) {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return }
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                floats[i] = Float(ints[i]) / 32768
            }
        }
        playFloat24k(floats)
    }

    func flushPlayback() {
        playLock.lock()
        playbackUntil = .distantPast
        playLock.unlock()
        playbackWatchdog?.cancel()
        player.stop()
        player.play()
        Task { @MainActor in self.isPlayingBack = false }
    }

    /// Call when the model finishes a turn so a stuck mute cannot swallow the next answer.
    func releaseUplink() {
        playLock.lock()
        playbackUntil = Date().addingTimeInterval(0.55)
        playLock.unlock()
        armUnmuteWatchdog()
    }

    private func playFloat24k(_ samples: [Float]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }
        if !player.isPlaying { player.play() }
        let duration = Double(samples.count) / 24_000
        let end = Date().addingTimeInterval(min(duration + 0.55, 8))
        playLock.lock()
        if end > playbackUntil { playbackUntil = end }
        playLock.unlock()
        Task { @MainActor in self.isPlayingBack = true }
        armUnmuteWatchdog()
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func armUnmuteWatchdog() {
        playbackWatchdog?.cancel()
        playLock.lock()
        let remaining = max(0.05, playbackUntil.timeIntervalSinceNow)
        playLock.unlock()
        playbackWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.playLock.lock()
            let stillMuted = Date() < self.playbackUntil
            self.playLock.unlock()
            if !stillMuted {
                self.isPlayingBack = false
                print("[Audio] uplink open")
            }
        }
    }

    nonisolated private func rawRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        if let channel = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<n { sum += channel[i] * channel[i] }
            return sqrt(sum / Float(n))
        }
        if let channel = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<n {
                let s = Float(channel[i]) / 32768
                sum += s * s
            }
            return sqrt(sum / Float(n))
        }
        return 0
    }

    nonisolated private func convertAndEmit(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        let raw = rawRMS(buffer)
        guard let converter = converterTo16k else {
            Task { @MainActor in self.inputLevel = raw }
            return
        }
        converter.reset()
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            print("[Audio] convert failed: \(error.localizedDescription)")
            Task { @MainActor in self.inputLevel = raw }
            return
        }
        guard let channel = out.int16ChannelData?[0], out.frameLength > 0 else {
            Task { @MainActor in self.inputLevel = raw }
            return
        }
        let frames = Int(out.frameLength)
        let data = Data(bytes: channel, count: frames * MemoryLayout<Int16>.size)
        Task { @MainActor in
            self.inputLevel = raw
            guard !self.isPlayingBack else { return }
            self.onPCM16k?(data)
        }
    }
}
