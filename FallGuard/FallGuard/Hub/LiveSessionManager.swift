import Foundation
import Combine
import FirebaseCore
import FirebaseAILogic

enum LiveModelID {
    static let preferred = "gemini-3.8-live"
    static let fallback = "gemini-3.1-flash-live-preview"
}

@MainActor
final class LiveSessionManager: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isWatching = false
    @Published private(set) var isCoaching = false
    @Published private(set) var modelName = LiveModelID.preferred
    @Published var status = "Live idle" {
        didSet {
            guard status != oldValue else { return }
            print("[Live] \(status)")
        }
    }
    @Published var lastTranscript = ""
    @Published var lastThought = ""
    @Published private(set) var watchFrames = 0

    var onToolCall: ((ToolCallEnvelope) async -> [String: Any])?
    var onAudioOut: ((Data) -> Void)?
    var onModelSpeaking: (() -> Void)?
    var onModelIdle: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var onHeard: ((String) -> Void)?
    var onSpoken: ((String) -> Void)?

    private var session: LiveSession?
    private var receiveTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastProfile: HomeProfile?
    private var userDisconnected = false
    private var mode: Mode = .watch
    private enum Mode { case watch, coaching }
    private var audioChunksOut = 0
    private var sendChain: Task<Void, Never>?
    private var speaking = false
    private var lastAudioOutAt = Date.distantPast
    private var lastFallSentAt: Date?
    private var fallCandidateSent = false
    private var lastCoachCueAt = Date.distantPast
    private var idleTask: Task<Void, Never>?
    private var userTalking = false
    private var userTalkStarted: Date?
    private var userQuietTask: Task<Void, Never>?
    private var lastHeardAt = Date.distantPast
    private var lastReplyNudgeAt = Date.distantPast
    private var uplinkChunks = 0
    private var closingSession: LiveSession?
    private var pendingWatchJPEG: Data?
    private var holdVideo = false

    func startWatch(profile: HomeProfile) async {
        lastProfile = profile
        userDisconnected = false
        mode = .watch
        await performConnect(profile: profile)
    }

    func connect(profile: HomeProfile) async {
        lastProfile = profile
        userDisconnected = false
        mode = .coaching
        await performConnect(profile: profile)
    }

    /// Cancels any in-flight connect and starts a new session. Only used after a fall.
    func forceReconnect(profile: HomeProfile) async {
        lastProfile = profile
        userDisconnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        tearDownListen()
        if let old = session {
            await old.close()
            session = nil
        }
        isConnected = false
        status = "Connecting Live…"
        await performConnect(profile: profile)
    }

    func disconnect() {
        userDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        sendChain?.cancel()
        sendChain = nil
        idleTask?.cancel()
        idleTask = nil
        userQuietTask?.cancel()
        userQuietTask = nil
        tearDownListen()
        if closingSession == nil {
            closingSession = session
        }
        session = nil
        isConnected = false
        isWatching = false
        isCoaching = false
        speaking = false
        userTalking = false
        userTalkStarted = nil
        lastFallSentAt = nil
        fallCandidateSent = false
        lastCoachCueAt = .distantPast
        lastAudioOutAt = .distantPast
        lastHeardAt = .distantPast
        lastReplyNudgeAt = .distantPast
        audioChunksOut = 0
        uplinkChunks = 0
        lastTranscript = ""
        lastThought = ""
        watchFrames = 0
        holdVideo = false
        status = "Live idle"
    }

    func reset() {
        disconnect()
    }

    func finishClose() async {
        if let old = closingSession {
            closingSession = nil
            await old.close()
        }
        pendingWatchJPEG = nil
    }

    /// Flip to coaching on the open watch session. Do not reconnect — that delayed speech.
    func ensureReady(profile: HomeProfile) async {
        lastProfile = profile
        userDisconnected = false
        if isConnected, session != nil {
            beginCoaching()
            return
        }
        mode = .coaching
        await performConnect(profile: profile)
    }

    func sendWatchLook() async {
        guard mode == .watch, isConnected, let session else { return }
        status = "Watch LOOK sent"
        await session.sendContent(
            "LOOK. Call watch_update now. Stay mute. If they are standing or reaching, fallen=false. If they are on the floor right now, fallen=true.",
            turnComplete: true
        )
    }

    func beginCoaching() {
        mode = .coaching
        isWatching = false
        isCoaching = true
        if isConnected {
            status = "Live coaching · \(modelName)"
        }
    }

    private func performConnect(profile: HomeProfile) async {
        if connectTask != nil {
            await connectTask?.value
            return
        }
        connectTask = Task { @MainActor in
            defer { connectTask = nil }
            await finishClose()
            tearDownListen()
            if let old = session {
                await old.close()
                session = nil
                isConnected = false
            }
            status = mode == .watch ? "Connecting watch…" : "Connecting Live…"
            if FirebaseApp.app() == nil,
               Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
                FirebaseApp.configure()
            }
            do {
                try await connect(model: LiveModelID.preferred, profile: profile)
            } catch {
                status = "\(LiveModelID.preferred) failed (\(error.localizedDescription)). Trying \(LiveModelID.fallback)…"
                do {
                    try await connect(model: LiveModelID.fallback, profile: profile)
                } catch {
                    status = "Live connect failed: \(error.localizedDescription)"
                    isConnected = false
                    isWatching = false
                    isCoaching = false
                    session = nil
                }
            }
        }
        await connectTask?.value
    }

    private func connect(model: String, profile: HomeProfile) async throws {
        let liveModel = FirebaseAI.firebaseAI(backend: .googleAI()).liveModel(
            modelName: model,
            generationConfig: LiveGenerationConfig(
                responseModalities: [.audio],
                speech: SpeechConfig(voiceName: "Aoede", languageCode: "en-US"),
                realtimeInputConfig: RealtimeInputConfig(
                    automaticActivityDetection: ActivityDetectionConfig(
                        startSensitivity: .low,
                        endSensitivity: .high,
                        prefixPadding: 0.15,
                        silenceDuration: 0.6
                    ),
                    activityHandling: .noInterrupt,
                    turnCoverage: .onlyActivity
                )
            ),
            tools: LiveTools.allDeclarations,
            systemInstruction: ModelContent(
                role: "system",
                parts: ProtocolPrompt.sessionText(profile)
            )
        )
        let session = try await liveModel.connect()
        self.session = session
        self.modelName = model
        self.isConnected = true
        self.isWatching = mode == .watch
        self.isCoaching = mode == .coaching
        self.audioChunksOut = 0
        self.speaking = false
        self.lastAudioOutAt = .distantPast
        self.idleTask?.cancel()
        self.userTalking = false
        self.uplinkChunks = 0
        self.status = mode == .watch ? "Watching floor · \(model)" : "Live connected · \(model)"
        listen(session)
    }

    var isModelSpeaking: Bool { speaking }

    func sendAudioPCM16k(_ data: Data) {
        guard mode == .coaching, let session, isConnected, !data.isEmpty else { return }
        if speaking || Date().timeIntervalSince(lastAudioOutAt) < 1.4 { return }
        uplinkChunks += 1
        if uplinkChunks == 1 || uplinkChunks % 40 == 0 {
            print("[Live] uplink frames=\(uplinkChunks)")
        }
        enqueue {
            await session.sendAudioRealtime(data)
        }
    }

    func sendJPEG(_ data: Data) {
        guard let session, isConnected, !data.isEmpty else { return }
        if holdVideo { return }
        if mode == .coaching, userTalking {
            return
        }
        if mode == .watch {
            watchFrames += 1
            if watchFrames == 1 || watchFrames % 15 == 0 {
                print("[Live] watch frames=\(watchFrames)")
                status = "Watching · \(watchFrames) frames"
            }
            pendingWatchJPEG = data
            enqueue { [weak self] in
                guard let self else { return }
                guard let jpeg = self.pendingWatchJPEG else { return }
                self.pendingWatchJPEG = nil
                guard let session = self.session, self.isConnected else { return }
                await session.sendVideoRealtime(jpeg, mimeType: "image/jpeg")
            }
            return
        }
        enqueue {
            await session.sendVideoRealtime(data, mimeType: "image/jpeg")
        }
    }

    func sendFallCandidate(_ sighting: FallSighting? = nil, clipFrozen: Bool = false) async {
        guard isConnected, let session else {
            status = "Fall blocked — Live not connected"
            return
        }
        if fallCandidateSent { return }
        fallCandidateSent = true
        lastFallSentAt = Date()
        status = "FALL_CANDIDATE sent"
        let visual = sighting.map {
            "Camera: \($0.brief) Reason: \($0.reason). Treat as a working picture, not a diagnosis."
        } ?? "Camera did not yet describe mechanism, landing side, impact, possible hurt, or severity."
        let videoLine = clipFrozen
            ? "Demo clip is paused at the fall — no new video. Coach by voice only; trust what you already saw."
            : "Camera is still live."
        await session.sendContent(
            """
            FALL_CANDIDATE. Person on floor. \(videoLine) \(visual) \
            Speak question 1 once, then listen. After they answer or stay silent, call situation with the facts. Keep talking. Desk texts family. Do not say you texted anyone until FAMILY_TEXTED.
            """,
            turnComplete: true
        )
    }

    func sendCoachFloorCue() async {
        guard mode == .coaching, isConnected, !holdVideo else { return }
        guard let session, !speaking else { return }
        if Date().timeIntervalSince(lastCoachCueAt) < 10 { return }
        lastCoachCueAt = Date()
        await session.sendContent(
            """
            SITUATION. Call situation with what you know. Keep talking. Desk writes the card and texts family. \
            Do not greet again. If they are trying to stand, say once not to panic and not to get up.
            """,
            turnComplete: true
        )
    }

    func notifyFamilyOnSpeaker() async {
        guard let session, isConnected else { return }
        await session.sendContent(
            "Family audio is now on the hub speaker. Tell the room their family is on speaker. Keep coaching. Do not give lift instructions.",
            turnComplete: true
        )
    }

    func cueLastMeasure(address: String, personName: String) async {
        guard let session, isConnected else { return }
        status = "LAST_MEASURE cue"
        await session.sendContent(
            """
            LAST_MEASURE. Ending A — stay down. Stay with \(personName). Address is \(address). \
            Do not say you texted family unless FAMILY_TEXTED arrives.
            """,
            turnComplete: true
        )
    }

    func cueFamilyTexted(contactName: String) async {
        guard let session, isConnected else { return }
        await session.sendContent(
            """
            FAMILY_TEXTED. \(contactName) has been texted and knows what happened. \
            At the next natural pause — never mid-answer — gently reassure them once, something like: \
            "I've let \(contactName) know, and they know you need help. You're not on your own." \
            Then keep comforting them.
            """,
            turnComplete: true
        )
    }

    func cueFamilyMessage(from contactName: String, text: String) async {
        guard isConnected, let session else { return }
        holdVideo = true
        status = "Family message"
        await session.sendContent(
            """
            FAMILY_MESSAGE. Stop everything else. Speak this to her now, in your own warm words. \
            Do not call tools. Do not greet again. Do not wait. \
            \(contactName) just texted: \(text)
            """,
            turnComplete: true
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            self.holdVideo = false
        }
    }

    func cueFamilyFailed() async {
        guard let session, isConnected else { return }
        await session.sendContent(
            "FAMILY_FAILED. Do not say you texted anyone. Say you are still with them.",
            turnComplete: true
        )
    }

    private func tearDownListen() {
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func listen(_ session: LiveSession) {
        tearDownListen()
        receiveTask = Task { [weak self] in
            do {
                for try await message in session.responses {
                    await self?.handle(message, session: session)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.speaking = false
                    let text = error.localizedDescription
                    self.status = "Live stream ended: \(text)"
                    self.isConnected = false
                    self.session = nil
                    if text.contains("parse a live message"), !self.userDisconnected,
                       let profile = self.lastProfile {
                        self.status = "Live frame skipped — reconnecting"
                        Task { await self.performConnect(profile: profile) }
                    }
                }
            }
        }
    }

    private func markSpeaking() {
        speaking = true
        lastAudioOutAt = Date()
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            if Date().timeIntervalSince(lastAudioOutAt) >= 0.4 {
                speaking = false
                onModelIdle?()
            }
        }
    }

    private static func pcmRMS(_ data: Data) -> Float {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var sum: Float = 0
            for i in 0..<count {
                let s = Float(samples[i]) / 32768
                sum += s * s
            }
            return sqrt(sum / Float(count))
        }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        sendChain = Task { [sendChain] in
            _ = await sendChain?.value
            await work()
        }
    }

    private func handle(_ message: LiveServerMessage, session: LiveSession) async {
        switch message.payload {
        case .content(let content):
            if let heard = content.inputAudioTranscription?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !heard.isEmpty {
                lastHeardAt = Date()
                lastTranscript = heard
                status = "Heard: \(heard)"
                onHeard?(heard)
            }
            if let spoken = content.outputAudioTranscription?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !spoken.isEmpty {
                lastTranscript = spoken
                onSpoken?(spoken)
            }
            if content.wasInterrupted {
                speaking = false
                idleTask?.cancel()
                status = "Live interrupted"
                onInterrupted?()
                onModelIdle?()
            }
            var heardAudio = false
            content.modelTurn?.parts.forEach { part in
                if let audio = part as? InlineDataPart, audio.mimeType.starts(with: "audio/pcm") {
                    heardAudio = true
                    if mode == .watch { return }
                    if Self.pcmRMS(audio.data) > 0.012 {
                        markSpeaking()
                        onModelSpeaking?()
                    }
                    audioChunksOut += 1
                    if audioChunksOut == 1 {
                        status = "Live speaking…"
                    }
                    onAudioOut?(audio.data)
                }
                if let text = part as? TextPart {
                    lastTranscript += text.text
                }
            }
            if content.isTurnComplete || content.isGenerationComplete {
                speaking = false
                idleTask?.cancel()
                onModelIdle?()
            }
            if !heardAudio, let parts = content.modelTurn?.parts, !parts.isEmpty, !content.isTurnComplete {
                status = "Live thinking…"
            }
        case .toolCall(let toolCall):
            let calls = toolCall.functionCalls ?? []
            status = "Tool: \(calls.map(\.name).joined(separator: ", "))"
            if mode == .watch, lastThought.isEmpty {
                lastThought = calls.map(\.name).joined(separator: ", ")
            }
            var responses: [FunctionResponsePart] = []
            for call in calls {
                let envelope = ToolCallEnvelope(
                    id: call.functionId ?? UUID().uuidString,
                    name: call.name,
                    args: call.args
                )
                let result = await onToolCall?(envelope) ?? ["ok": false, "error": "no handler"]
                responses.append(
                    FunctionResponsePart(
                        name: call.name,
                        response: JSONBridge.object(result),
                        functionId: call.functionId
                    )
                )
            }
            await session.sendFunctionResponses(responses)
        default:
            break
        }
    }
}
