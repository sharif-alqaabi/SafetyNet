import AVFoundation
import Foundation
import Speech

/// On-device / Apple speech-to-text so the hub can force a Live reply.
/// Gemini Live VAD was not closing user turns on this session.
@MainActor
final class SpeechRelay: ObservableObject {
    @Published var lastHeard = ""
    @Published var status = "Speech idle"

    var onUtterance: ((String) -> Void)?
    var isListeningEnabled = true

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pending = ""
    private var lastCommitted = ""
    private var settleTask: Task<Void, Never>?
    private let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func start() async {
        let auth: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard auth == .authorized else {
            status = "Speech permission denied"
            return
        }
        guard recognizer != nil else {
            status = "Speech recognizer unavailable"
            return
        }
        restart()
        status = "Speech listening"
    }

    func stop() {
        settleTask?.cancel()
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        status = "Speech idle"
    }

    func appendPCM16k(_ data: Data) {
        guard isListeningEnabled, let request, !data.isEmpty else { return }
        let frames = data.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress,
                  let dst = buffer.int16ChannelData?[0] else { return }
            dst.update(from: src, count: frames)
        }
        request.append(buffer)
    }

    private func restart() {
        settleTask?.cancel()
        task?.cancel()
        request?.endAudio()
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    self.pending = text
                    self.status = "Hearing: \(text)"
                    if result.isFinal {
                        self.commit(text)
                        self.restart()
                    } else {
                        self.scheduleCommit()
                    }
                } else if error != nil {
                    self.restart()
                }
            }
        }
    }

    private func scheduleCommit() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self.commit(self.pending)
            self.restart()
        }
    }

    private func commit(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return }
        if cleaned.caseInsensitiveCompare(lastCommitted) == .orderedSame { return }
        lastCommitted = cleaned
        pending = ""
        lastHeard = cleaned
        status = "Heard: \(cleaned)"
        onUtterance?(cleaned)
    }
}
