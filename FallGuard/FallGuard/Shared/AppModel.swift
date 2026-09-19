import Combine
import Foundation
import os
import SwiftUI
import UIKit

private let hubLog = Logger(subsystem: "com.watchfall.FallGuard", category: "hub")

@MainActor
final class AppModel: ObservableObject {
    @Published var role: DeviceRole {
        didSet { UserDefaults.standard.set(role.rawValue, forKey: "deviceRole") }
    }
    @Published var profile: HomeProfile {
        didSet { persistProfile() }
    }
    @Published var showDevPreview = true
    @Published var backendBase = AppModel.resolvedBackendBase() {
        didSet { UserDefaults.standard.set(backendBase, forKey: "backendBase") }
    }
    @Published var incident: Incident?
    @Published var banner = "MONITORING — do not lock"
    @Published var log: [String] = []
    @Published var lastMeasureFired = false
    @Published var familyOnTheWay = false

    let camera = CameraRearService()
    let audio = AudioIO()
    let live = LiveSessionManager()
    let speech = SpeechRelay()
    let pose = PoseTrigger()
    let clipReplay = ClipReplay()
    let talk = TalkService()

    private var api: APIClient
    private var silenceTask: Task<Void, Never>?
    private var relativeTask: Task<Void, Never>?
    private var watchLookTask: Task<Void, Never>?
    private var coachLookTask: Task<Void, Never>?
    private var clipSessionTask: Task<Void, Never>?
    private var familyInboxTask: Task<Void, Never>?
    private var watchingClip = false
    private var fallStarted: Date?
    private var notifiedFamily = false
    private var familyNotifyWasResolved = false
    private var calledFamily = false
    private var calledEmergency = false
    private var victimSpoke = false
    private var fallInFlight = false
    private var clipSawStanding = false
    private var lastSighting: FallSighting?
    private var hubStarted = false
    private var cancellables = Set<AnyCancellable>()
    private var coachHeard: [String] = []
    private var coachSpoken: [String] = []
    private var lastSituationNote = ""
    private var deskRunning = false
    private var deskQueued: String?
    private var familyCueSent = false
    private var notifyInFlight = false
    private var clipFrozenAfterFall = false

    init() {
        let storedRole = UserDefaults.standard.string(forKey: "deviceRole").flatMap(DeviceRole.init)
        role = storedRole ?? .hub
        profile = Self.loadProfile()
        api = APIClient(baseURL: URL(string: AppModel.resolvedBackendBase())!)
        wire()
    }

    /// Venue Wi-Fi isolates clients, so the phone reaches the Mac through the ngrok tunnel.
    /// Works on any network including cellular. URL changes if ngrok restarts.
    private static let lanBackend = "https://angla-unvitiable-pearline.ngrok-free.dev"

    private static func resolvedBackendBase() -> String {
        UserDefaults.standard.set(lanBackend, forKey: "backendBase")
        return lanBackend
    }

    func applyBackend() {
        if let url = URL(string: backendBase) {
            api = APIClient(baseURL: url)
        }
    }

    func startHub() {
        if hubStarted { return }
        hubStarted = true
        UIApplication.shared.isIdleTimerDisabled = true
        UIScreen.main.brightness = 1
        banner = "MONITORING — do not lock"
        note("Hub starting")
        camera.onJPEG = { [weak self] jpeg in
            guard let self, !self.clipReplay.isPlaying else { return }
            self.ingestWatchFrame(jpeg)
        }
        clipReplay.onJPEG = { [weak self] jpeg in
            guard let self, !self.clipFrozenAfterFall else { return }
            self.ingestWatchFrame(jpeg)
        }
        camera.start()
        camera.$isRunning
            .filter { $0 }
            .first()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        try self.audio.restart()
                        self.note("Mic restarted after camera")
                    } catch {
                        self.note("Mic restart failed: \(error.localizedDescription)")
                    }
                }
            }
            .store(in: &cancellables)
        audio.$isPlayingBack
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                self?.speech.isListeningEnabled = !playing
            }
            .store(in: &cancellables)
        audio.onPCM16k = { [weak self] data in
            guard let self, !self.audio.isPlayingBack, !self.live.isModelSpeaking else { return }
            self.live.sendAudioPCM16k(data)
        }
        pose.onFall = { [weak self] in
            Task { await self?.handleFall(source: "pose") }
        }
        live.onAudioOut = { [weak self] data in
            guard let self, self.live.isCoaching else { return }
            self.audio.playPCM24k(data)
        }
        live.onModelSpeaking = { [weak self] in
            guard let self, self.live.isCoaching else { return }
            self.speech.isListeningEnabled = false
            self.banner = "AGENT SPEAKING"
        }
        live.onModelIdle = { [weak self] in
            self?.audio.releaseUplink()
            if self?.banner == "AGENT SPEAKING" {
                self?.banner = self?.incident == nil ? "MONITORING — do not lock" : "FALL — stay down"
            }
        }
        live.onInterrupted = { [weak self] in
            self?.audio.flushPlayback()
        }
        live.onHeard = { [weak self] text in
            guard let self, self.live.isCoaching else { return }
            self.coachHeard.append(text)
            self.note("Heard: \(text)")
            if self.watchingClip { return }
            self.markVictimSpoke()
        }
        live.onSpoken = { [weak self] text in
            self?.coachSpoken.append(text)
        }
        live.onToolCall = { [weak self] call in
            await self?.runTool(call) ?? ["ok": false]
        }
        Task {
            await audio.startWithPermission()
            if let micError = audio.lastError {
                note("Audio: \(micError)")
            } else if audio.isArmed {
                note("Mic armed — tap Start real session to watch")
            }
        }
        Task { await checkBackend() }
    }

    /// Pings the Mac backend so the Local Network prompt fires at launch, not mid-fall,
    /// and so the console says plainly whether texts can go out.
    func checkBackend() async {
        do {
            try await api.health()
            note("Backend OK — \(backendBase)")
        } catch {
            banner = "BACKEND UNREACHABLE — no texts"
            note("Backend unreachable at \(backendBase): \(error.localizedDescription)")
            note("Check: same Wi-Fi as the Mac + Settings > Privacy > Local Network > FallGuard")
        }
    }

    func stopHub() {
        guard hubStarted else { return }
        hubStarted = false
        silenceTask?.cancel()
        relativeTask?.cancel()
        watchLookTask?.cancel()
        coachLookTask?.cancel()
        familyInboxTask?.cancel()
        camera.stop()
        audio.stop()
        speech.stop()
        clipReplay.stop()
        live.disconnect()
        pose.reset()
        fallStarted = nil
        fallInFlight = false
        clipSawStanding = false
        watchingClip = false
        lastSighting = nil
        UIApplication.shared.isIdleTimerDisabled = false
        banner = "Hub stopped"
    }

    func speakerTest() {
        audio.playTone()
        note("Speaker test")
    }

    var isSessionActive: Bool {
        incident != nil
            || fallStarted != nil
            || lastMeasureFired
            || familyOnTheWay
            || live.isCoaching
    }

    func endLiveSession() {
        resetHub(restartCamera: true)
        banner = "MONITORING — do not lock"
        note("Session reset — monitoring")
    }

    private func resetHub(restartCamera: Bool) {
        silenceTask?.cancel()
        relativeTask?.cancel()
        watchLookTask?.cancel()
        coachLookTask?.cancel()
        clipSessionTask?.cancel()
        familyInboxTask?.cancel()
        silenceTask = nil
        relativeTask = nil
        watchLookTask = nil
        coachLookTask = nil
        clipSessionTask = nil
        familyInboxTask = nil
        audio.flushPlayback()
        clipReplay.stop()
        live.reset()
        pose.reset()
        speech.lastHeard = ""
        speech.status = "Speech idle"
        fallStarted = nil
        fallInFlight = false
        clipSawStanding = false
        watchingClip = false
        lastSighting = nil
        victimSpoke = false
        coachHeard = []
        coachSpoken = []
        lastSituationNote = ""
        deskQueued = nil
        familyCueSent = false
        notifyInFlight = false
        clipFrozenAfterFall = false
        notifiedFamily = false
        familyNotifyWasResolved = false
        calledFamily = false
        calledEmergency = false
        lastMeasureFired = false
        familyOnTheWay = false
        incident = nil
        log = []
        camera.setJPEGInterval(1)
        if restartCamera {
            if !camera.isRunning { camera.start() }
            camera.resumeJPEG()
        }
    }

    func startRealSession() {
        guard !live.isWatching, !live.isCoaching, !fallInFlight else { return }
        camera.setJPEGInterval(0.2)
        banner = "WATCHING — do not lock"
        note("Start real session")
        Task {
            await live.startWatch(profile: profile)
            if live.isWatching {
                note("Gemini watching the camera")
                startWatchLooks()
            }
        }
    }

    func startRealSessionFromClip() {
        guard ClipReplay.bundledURL != nil else {
            note("Test clip missing from app bundle")
            return
        }
        resetHub(restartCamera: false)
        watchingClip = true
        camera.pauseJPEG()
        camera.stop()
        banner = "WATCHING CLIP — live from standing"
        note("Test clip: real flow — watch, then speak, then family if no reply")
        clipSessionTask = Task {
            await live.finishClose()
            await live.startWatch(profile: profile)
            guard !Task.isCancelled, live.isWatching else {
                if !Task.isCancelled {
                    camera.start()
                    camera.resumeJPEG()
                    note("Watch did not connect — clip not started")
                }
                return
            }
            note("Gemini watching the clip live — standing first, then the fall")
            startWatchLooks(waitForClip: true, interval: 2)
            startClipFallBackup()
            await clipReplay.playBundledClip()
            if !Task.isCancelled, live.isWatching, !live.isCoaching {
                note("Test clip finished — still watching clip, camera still off")
            }
        }
    }

    private func startWatchLooks(waitForClip: Bool = false, interval: TimeInterval = 3) {
        watchLookTask?.cancel()
        watchLookTask = Task {
            if waitForClip {
                while !Task.isCancelled, !clipReplay.isPlaying {
                    if clipSessionTask == nil { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            } else {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            while !Task.isCancelled, live.isWatching, !live.isCoaching {
                await live.sendWatchLook()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func startClipFallBackup() {
        Task {
            while !Task.isCancelled, watchingClip, live.isWatching, !live.isCoaching, !fallInFlight {
                if clipReplay.playhead >= 10 {
                    note("Clip backup: on the floor — starting coach")
                    if lastSighting == nil {
                        lastSighting = FallSighting(
                            reason: "Clip: person on the floor",
                            mechanism: "collapse",
                            direction: "right",
                            impact: ["right hip", "right shoulder"],
                            hurt: ["right hip", "right shoulder"],
                            severity: .high,
                            hurtNote: "Looks like a side landing from the chair.",
                            room: profile.room
                        )
                    }
                    await handleFall(source: "clip")
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func startCoachLooks() {
        coachLookTask?.cancel()
        coachLookTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled, live.isCoaching {
                await live.sendCoachFloorCue()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func ingestWatchFrame(_ jpeg: Data) {
        live.sendJPEG(jpeg)
        pose.ingest(jpeg: jpeg)
        camera.clipBuffer.append(jpeg)
    }

    func simulateFall() {
        Task { await handleFall(source: "simulate") }
    }

    var canEndSession: Bool {
        isSessionActive || live.isWatching || live.status.hasPrefix("Connecting watch")
    }

    func handleFall(source: String) async {
        if source != "simulate", fallStarted != nil || fallInFlight { return }
        fallInFlight = true
        camera.setJPEGInterval(watchingClip ? 1 : 3)
        silenceTask?.cancel()
        relativeTask?.cancel()
        live.beginCoaching()
        if !live.isConnected {
            await live.ensureReady(profile: profile)
        }
        if !live.isConnected {
            fallInFlight = false
            camera.setJPEGInterval(1)
            note("Fall: Live did not connect — check status line")
            banner = "LIVE OFFLINE"
            if incident == nil {
                incident = Incident.draft(profile: profile)
            }
            await textFamilyNow(reason: "\(profile.personName) fell in the \(profile.room). Live was offline.")
            return
        }
        fallStarted = Date()
        victimSpoke = false
        coachHeard = []
        coachSpoken = []
        lastSituationNote = lastSighting?.brief ?? ""
        familyCueSent = false
        notifyInFlight = false
        notifiedFamily = false
        familyNotifyWasResolved = false
        calledFamily = false
        calledEmergency = false
        lastMeasureFired = false
        familyOnTheWay = false
        var card = Incident.draft(profile: profile)
        if source == "gemini", let seen = lastSighting {
            card.mechanism = seen.mechanism
            card.direction = seen.direction
            card.impact = seen.impact
            card.hurt = seen.hurt
            card.hurtNote = seen.hurtNote
            card.severity = seen.severity
            if !seen.room.isEmpty { card.room = seen.room }
            card.notes = "Triggered by \(source). \(seen.brief) \(seen.reason)"
            note(seen.brief)
        } else {
            card.mechanism = source == "simulate" ? "simulated" : "unknown"
            card.notes = "Triggered by \(source)"
        }
        incident = card
        banner = "FALL — stay down"
        note("FALL_CANDIDATE via \(source) — coach now")
        if watchingClip {
            clipFrozenAfterFall = true
            clipReplay.freezeAtFall()
            watchLookTask?.cancel()
            note("Clip frozen — voice coaching only")
        }
        await live.sendFallCandidate(lastSighting, clipFrozen: watchingClip)
        startSilenceGuardrail()
        startFamilyInboxPoll()
        requestDesk(trigger: "fall")
        Task { [weak self] in
            guard let self else { return }
            var uploaded = card
            uploaded.liveURL = "\(self.backendBase)/family/\(uploaded.id)"
            self.incident = uploaded
            try? await self.api.upsertIncident(uploaded)
            await self.textFamilyNow(
                reason: self.lastSighting.map { "\($0.brief) \($0.reason)" }
                    ?? "\(self.profile.personName) fell in the \(self.profile.room) at \(self.profile.address). Still on the floor."
            )
            await self.uploadFrozenClip(into: &uploaded)
            if uploaded.clipURL != nil {
                self.incident = uploaded
                try? await self.api.upsertIncident(uploaded)
            }
        }
    }

    func markVictimSpoke() {
        victimSpoke = true
        silenceTask?.cancel()
    }

    func markOnTheWay() {
        familyOnTheWay = true
        relativeTask?.cancel()
        if var card = incident {
            card.familyAnswered = true
            card.updatedAt = Date()
            incident = card
            Task { try? await api.upsertIncident(card) }
        }
    }

    private func startSilenceGuardrail() {
        silenceTask?.cancel()
        silenceTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            if !watchingClip, victimSpoke { return }
            if var card = incident {
                card.responsive = false
                incident = card
            }
            note("15s silence — texting family")
            lastSituationNote = "Silent after 15 seconds. Still on the floor."
            if !notifiedFamily {
                await textFamilyNow(reason: "No response from \(profile.personName) after 15 seconds")
            }
            requestDesk(trigger: "silence")
        }
    }

    private func startRelativeGuardrail() {
        if lastMeasureFired { return }
        if let card = incident, shouldSkipRung(card) { return }
        relativeTask?.cancel()
        relativeTask = Task {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled, !familyOnTheWay, !(incident?.familyAnswered ?? false) else { return }
            note("Relative silent — last measure")
            await lastMeasure(reason: "No response from relative")
        }
    }

    private func shouldSkipRung(_ card: Incident) -> Bool {
        if card.recommend911 || card.asksAmbulance || card.severity == .critical { return true }
        if card.ableToMove == false { return true }
        let sites = card.impact + card.hurt
        let hitHead = sites.contains { $0.localizedCaseInsensitiveContains("head") }
        if hitHead && profile.bloodThinners { return true }
        let down = card.timeDownSec > 0 ? card.timeDownSec : Int(Date().timeIntervalSince(fallStarted ?? Date()))
        if !card.responsive && down >= 15 { return true }
        return false
    }

    private func escalateSkipRung(reason: String) async {
        if lastMeasureFired, notifiedFamily, calledFamily || calledEmergency { return }
        relativeTask?.cancel()
        if var card = incident {
            card.recommend911 = true
            card.severity = .critical
            card.cleared = false
            card.notes = [card.notes, reason].filter { !$0.isEmpty }.joined(separator: " · ")
            incident = card
            try? await api.upsertIncident(card)
        }
        if !notifiedFamily {
            let sent = await notifyAndCallFamily(fallback: true, reason: reason)
            if sent {
                await cueFamilyTextedOnce()
            } else {
                await live.cueFamilyFailed()
            }
        }
        await lastMeasure(reason: reason)
    }

    private func notifyFamilyResolved(summary: String) async {
        guard var card = incident else { return }
        if notifiedFamily && !familyNotifyWasResolved { return }
        card.cleared = true
        if card.severity == .high { card.severity = .moderate }
        card.notes = [card.notes, summary].filter { !$0.isEmpty }.joined(separator: " · ")
        card.timeDownSec = Int(Date().timeIntervalSince(fallStarted ?? Date()))
        incident = card
        try? await api.upsertIncident(card)
        do {
            try await api.notifyFamily(
                NotifyRequest(
                    incidentId: card.id,
                    severity: card.severity.rawValue,
                    summary: summary,
                    stillOnFloor: false,
                    urgency: "resolved",
                    clipURL: card.clipURL,
                    liveURL: card.liveURL
                )
            )
            notifiedFamily = true
            familyNotifyWasResolved = true
            card.familyNotified = true
            incident = card
            relativeTask?.cancel()
            note("Family resolved note")
        } catch {
            note("Notify failed: \(error.localizedDescription)")
        }
    }

    /// Tells the coach exactly once per incident that family was texted,
    /// so it doesn't repeat "I've let Alex know" from multiple code paths.
    private func cueFamilyTextedOnce() async {
        guard !familyCueSent else { return }
        familyCueSent = true
        await live.cueFamilyTexted(contactName: profile.contactName)
    }

    private func textFamilyNow(reason: String) async {
        note("Texting family via Photon (background)")
        let sent = await notifyAndCallFamily(fallback: true, reason: reason)
        if sent {
            // Let the coach greet and hear an answer before it brings up Alex.
            let elapsed = Date().timeIntervalSince(fallStarted ?? Date())
            let wait = max(2, 20 - elapsed)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if live.isCoaching {
                await cueFamilyTextedOnce()
            }
        } else {
            await live.cueFamilyFailed()
        }
    }

    @discardableResult
    private func notifyAndCallFamily(fallback: Bool, reason: String) async -> Bool {
        guard var card = incident else { return false }
        card.cleared = false
        card.timeDownSec = Int(Date().timeIntervalSince(fallStarted ?? Date()))
        if fallback { card.responsive = victimSpoke && !watchingClip }
        card.notes = [card.notes, reason].filter { !$0.isEmpty }.joined(separator: " · ")
        if card.severity == .low { card.severity = .high }
        incident = card
        try? await api.upsertIncident(card)

        let canNotify = !notifiedFamily || familyNotifyWasResolved
        guard canNotify, !notifyInFlight else { return notifiedFamily }
        notifyInFlight = true
        defer { notifyInFlight = false }
        familyNotifyWasResolved = false
        note("Photon POST \(backendBase)/notify")
        let summary = fallback
            ? "\(profile.personName) fell in the \(card.room) at \(card.address). \(reason). Still on the floor."
            : reason
        for attempt in 1...3 {
            do {
                try await api.notifyFamily(
                    NotifyRequest(
                        incidentId: card.id,
                        severity: card.severity.rawValue,
                        summary: summary,
                        stillOnFloor: true,
                        urgency: "urgent",
                        clipURL: card.clipURL,
                        liveURL: card.liveURL
                    )
                )
                notifiedFamily = true
                card.familyNotified = true
                incident = card
                note("Family notified (urgent)")
                return true
            } catch {
                note("Notify failed (\(attempt)/3): \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        return false
    }

    func lastMeasure(reason: String) async {
        lastMeasureFired = true
        banner = "LAST MEASURE"
        relativeTask?.cancel()
        guard var card = incident else { return }
        card.severity = .critical
        card.recommend911 = true
        card.cleared = false
        card.notes = [card.notes, "911 recommended: \(reason)"].joined(separator: " · ")
        card.timeDownSec = Int(Date().timeIntervalSince(fallStarted ?? Date()))
        incident = card
        try? await api.upsertIncident(card)
        note("Last measure is voice-only — no second family text")
    }

    func connectFamilyAudio() async {
        guard let card = incident else { return }
        do {
            try await api.connectFamilyAudio(incidentId: card.id)
            var updated = card
            updated.familyPatched = true
            updated.familyAnswered = true
            incident = updated
            await live.notifyFamilyOnSpeaker()
            banner = "FAMILY ON SPEAKER"
            note("Family patched to hub speaker")
        } catch {
            note("Patch failed: \(error.localizedDescription)")
        }
    }

    private func uploadFrozenClip(into card: inout Incident) async {
        let frames = Self.sampleClipFrames(camera.clipBuffer.freeze(), maxCount: 24)
        guard !frames.isEmpty else {
            note("No fall frames to upload")
            return
        }
        do {
            let url = try await api.uploadClip(incidentId: card.id, jpegFrames: frames)
            card.clipURL = url
            card.liveURL = "\(backendBase)/family/\(card.id)"
            note("Fall clip uploaded (\(frames.count) frames)")
        } catch {
            note("Clip upload: \(error.localizedDescription)")
        }
    }

    private static func sampleClipFrames(_ frames: [Data], maxCount: Int) -> [Data] {
        guard frames.count > maxCount, maxCount > 1 else { return frames }
        return (0..<maxCount).map { index in
            frames[index * (frames.count - 1) / (maxCount - 1)]
        }
    }

    private func startFamilyInboxPoll() {
        familyInboxTask?.cancel()
        familyInboxTask = Task {
            while !Task.isCancelled, incident != nil {
                await deliverFamilyInbox()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func deliverFamilyInbox() async {
        guard let card = incident else { return }
        do {
            let messages = try await api.fetchFamilyInbox(homeCode: profile.homeCode, incidentId: card.id)
            guard !messages.isEmpty else { return }
            note("Family said: \(messages.map(\.text).joined(separator: " | "))")
            markOnTheWay()
            coachLookTask?.cancel()
            camera.pauseJPEG()
            for item in messages {
                await live.cueFamilyMessage(from: profile.contactName, text: item.text)
            }
            try? await api.ackFamilyInbox(homeCode: profile.homeCode, ids: messages.map(\.id))
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !watchingClip { camera.resumeJPEG() }
        } catch {
            note("Family inbox: \(error.localizedDescription)")
        }
    }

    private func runTool(_ call: ToolCallEnvelope) async -> [String: Any] {
        note("Tool \(call.name)")
        switch call.name {
        case "situation", "write_incident", "notify_family":
            acceptHandoff(call)
            return ["ok": true, "desk": "working"]
        case "watch_update", "report_fall":
            let reason = call.string("reason") ?? "no reason"
            let fallen = call.bool("fallen") ?? (call.name == "report_fall")
            var seen = FallSighting(
                reason: reason,
                mechanism: call.string("mechanism") ?? "unknown",
                direction: call.string("direction") ?? "unknown",
                impact: call.strings("impact"),
                hurt: call.strings("hurt"),
                severity: IncidentSeverity.parse(call.string("severity")) ?? .high,
                hurtNote: call.string("hurt_note") ?? "",
                room: call.string("room") ?? ""
            )
            if fallen { seen = seen.guessed() }
            lastSighting = seen
            live.lastThought = (fallen ? "FALL: " : "Watch: ") + "\(reason)\n\(seen.brief)"
            note(live.lastThought)
            let visible = call.bool("person_visible") ?? fallen
            if watchingClip || clipReplay.isPlaying {
                if visible, !fallen { clipSawStanding = true }
                if pose.wasUpright { clipSawStanding = true }
                if clipReplay.playhead >= 8 { clipSawStanding = true }
            }
            let clipLiveFall = !watchingClip
                || clipSawStanding
                || clipReplay.playhead >= 3
            if fallen, visible, clipLiveFall {
                watchLookTask?.cancel()
                Task { await handleFall(source: "gemini") }
            }
            return ["ok": true, "fallen": fallen]
        case "place_voice_call", "connect_family_audio":
            return ["ok": false, "error": "voice disabled — desk texts family"]
        default:
            return ["ok": false, "error": "unknown tool"]
        }
    }

    private func acceptHandoff(_ call: ToolCallEnvelope) {
        let heard = call.string("heard") ?? ""
        if !heard.isEmpty {
            coachHeard.append(heard)
            if !watchingClip { markVictimSpoke() }
        }
        if call.bool("responsive") == true, !watchingClip {
            markVictimSpoke()
        }
        var bits: [String] = []
        if let hurting = call.string("hurting"), !hurting.isEmpty { bits.append("Hurting: \(hurting)") }
        if let note = call.string("note") ?? call.string("summary"), !note.isEmpty { bits.append(note) }
        if let ending = call.string("ending"), !ending.isEmpty { bits.append("Ending \(ending)") }
        if call.bool("silent") == true { bits.append("Silent") }
        if call.bool("still_on_floor") == true { bits.append("Still on floor") }
        if call.bool("struggling") == true { bits.append("Struggling to get up") }
        if let move = call.bool("can_move") { bits.append(move ? "Can move" : "Cannot move") }
        lastSituationNote = bits.joined(separator: ". ")
        live.lastThought = "Desk handoff: \(lastSituationNote)"
        note("Handoff to desk — Live stays on the call")
        requestDesk(trigger: call.name)
    }

    private func requestDesk(trigger: String) {
        if deskRunning {
            deskQueued = trigger
            return
        }
        Task { await runDesk(trigger: trigger) }
    }

    private func runDesk(trigger: String) async {
        guard let card = incident else { return }
        deskRunning = true
        defer {
            deskRunning = false
            if let next = deskQueued {
                deskQueued = nil
                Task { await runDesk(trigger: next) }
            }
        }
        let down = Int(Date().timeIntervalSince(fallStarted ?? Date()))
        note("Desk agent writing card (\(trigger))")
        let handoff = DeskHandoff(
            trigger: trigger,
            profile: profile,
            sighting: lastSighting,
            incident: card,
            heard: coachHeard,
            spoken: coachSpoken,
            situationNote: lastSituationNote,
            silent: watchingClip || !victimSpoke,
            victimSpoke: victimSpoke && !watchingClip,
            timeDownSec: down,
            watchingClip: watchingClip
        )
        do {
            let decision = try await withTimeout(seconds: 12) {
                try await DeskAgent.decide(handoff)
            }
            await applyDesk(decision, trigger: trigger)
        } catch {
            note("Desk failed: \(error.localizedDescription)")
            if !notifiedFamily, trigger == "silence" || trigger == "fall" || watchingClip {
                let sent = await notifyAndCallFamily(
                    fallback: true,
                    reason: lastSituationNote.isEmpty
                        ? "\(profile.personName) fell in the \(profile.room). Still on the floor."
                        : lastSituationNote
                )
                if sent {
                    await cueFamilyTextedOnce()
                    startRelativeGuardrail()
                } else {
                    await live.cueFamilyFailed()
                }
            }
        }
    }

    private func applyDesk(_ decision: DeskDecision, trigger: String) async {
        guard var card = incident else { return }
        if let value = decision.mechanism, !value.isEmpty { card.mechanism = value }
        if let value = decision.direction, !value.isEmpty { card.direction = value }
        if let value = decision.impact, !value.isEmpty { card.impact = value }
        if let value = decision.hurt, !value.isEmpty { card.hurt = value }
        if let value = decision.hurtNote, !value.isEmpty { card.hurtNote = value }
        if let sev = IncidentSeverity.parse(decision.severity) { card.severity = sev }
        if let value = decision.responsive { card.responsive = value }
        if let value = decision.ableToMove { card.ableToMove = value }
        if decision.asksAmbulance == true { card.asksAmbulance = true }
        if decision.cleared == true { card.cleared = true }
        if decision.recommend911 == true {
            card.recommend911 = true
            card.severity = .critical
            card.cleared = false
        }
        if let value = decision.notes, !value.isEmpty {
            card.notes = [card.notes, value].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        card.timeDownSec = Int(Date().timeIntervalSince(fallStarted ?? Date()))
        card.updatedAt = Date()
        incident = card
        try? await api.upsertIncident(card)
        note("Desk card: \(card.hurtNote.isEmpty ? card.notes : card.hurtNote)")

        let notify = (decision.notify ?? "").lowercased()
        let summary = decision.familySummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let familyText = (summary?.isEmpty == false)
            ? summary!
            : "\(profile.personName) fell in the \(card.room) at \(card.address). Still on the floor."

        if notify == "resolved" {
            await notifyFamilyResolved(summary: familyText)
            if notifiedFamily {
                await cueFamilyTextedOnce()
            } else {
                await live.cueFamilyFailed()
            }
            return
        }

        let mustText = !notifiedFamily && !notifyInFlight && (
            notify == "urgent"
            || decision.recommend911 == true
        )
        guard mustText else { return }

        let sent = await notifyAndCallFamily(fallback: false, reason: familyText)
        if sent {
            await cueFamilyTextedOnce()
        } else {
            await live.cueFamilyFailed()
        }
        if decision.recommend911 == true, !lastMeasureFired {
            await lastMeasure(reason: familyText)
            await live.cueLastMeasure(address: profile.address, personName: profile.personName)
        }
    }

    func refreshFamilyIncident() async {
        do {
            if let latest = try await api.latestIncident(homeCode: profile.homeCode) {
                incident = latest
            }
        } catch {
            note("Family refresh: \(error.localizedDescription)")
        }
    }

    private func wire() {
        live.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        audio.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func note(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        log.insert("\(stamp.suffix(8))  \(line)", at: 0)
        if log.count > 80 { log.removeLast() }
        print("[Hub] \(line)")
        hubLog.info("\(line, privacy: .public)")
    }

    private func persistProfile() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: "homeProfile")
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw APIError.http("Desk timed out")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private static func loadProfile() -> HomeProfile {
        if let data = UserDefaults.standard.data(forKey: "homeProfile"),
           let profile = try? JSONDecoder().decode(HomeProfile.self, from: data) {
            return profile
        }
        return .demo
    }
}
