import SwiftUI

struct MonitorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var live: LiveSessionManager
    @ObservedObject private var audio: AudioIO
    @ObservedObject private var speech: SpeechRelay
    @ObservedObject private var clip: ClipReplay

    init(model: AppModel) {
        self.model = model
        self.live = model.live
        self.audio = model.audio
        self.speech = model.speech
        self.clip = model.clipReplay
    }

    var body: some View {
        VStack(spacing: 16) {
            statusPill
            if model.showDevPreview {
                ZStack(alignment: .bottomLeading) {
                    if clip.isPlaying {
                        ClipPlayerView(player: clip.player)
                            .frame(height: 220)
                    } else if let image = clip.currentImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 220)
                            .clipped()
                    } else {
                        RearPreviewView(session: model.camera.session)
                            .frame(height: 220)
                    }
                    Text(clip.isPlaying || clip.currentImage != nil
                         ? clip.clockLabel
                         : "DEV PREVIEW — hide for judges")
                        .font(.caption2.weight(.semibold))
                        .padding(8)
                        .background(.black.opacity(0.55))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            incidentStrip
            HStack(spacing: 12) {
                Button("Simulate fall") { model.simulateFall() }
                    .buttonStyle(HubButtonStyle(kind: .primary))
                    .accessibilityLabel("Simulate a fall")
                if !live.isWatching, !live.isCoaching, !clip.isPlaying {
                    Button("Start real session") { model.startRealSession() }
                        .buttonStyle(HubButtonStyle(kind: .secondary))
                        .accessibilityLabel("Start Gemini watching the floor")
                }
                Button("Test clip") { model.startRealSessionFromClip() }
                    .buttonStyle(HubButtonStyle(kind: .secondary))
                    .accessibilityLabel("Restart the one-minute test clip from the beginning")
            }
            HStack(spacing: 12) {
                Button("Speaker test") { model.speakerTest() }
                    .buttonStyle(HubButtonStyle(kind: .secondary))
                if model.canEndSession {
                    Button("End session") { model.endLiveSession() }
                        .buttonStyle(HubButtonStyle(kind: .danger))
                        .accessibilityLabel("End the session and reset the hub")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    readinessPill("Live", ok: live.isCoaching)
                    readinessPill("Watch", ok: live.isWatching)
                    readinessPill(audio.isPlayingBack ? "Mic: muted" : (audio.inputLevel > 0.02 ? "Mic: hearing you" : "Mic"), ok: audio.isArmed)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(audio.isPlayingBack ? Color.gray : (audio.inputLevel > 0.02 ? Color.green : Color.orange))
                            .frame(width: max(6, geo.size.width * CGFloat(min(audio.inputLevel * 8, 1))))
                    }
                }
                .frame(height: 10)
                Text(audio.isPlayingBack
                     ? "Speaker echo — not sent to the agent"
                     : (audio.inputLevel > 0.02 ? "Mic is picking you up" : "Talk now — this bar should move"))
                    .font(.caption)
                    .foregroundStyle(audio.isPlayingBack ? Color.secondary : (audio.inputLevel > 0.02 ? Color.green : Color.secondary))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(live.status)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !live.lastThought.isEmpty {
                        Text(live.lastThought)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !speech.status.isEmpty {
                        Text(speech.status)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let micError = audio.lastError {
                        Text(micError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding()
        .onAppear { model.startHub() }
    }

    private var statusPill: some View {
        Text(model.banner)
            .font(.headline.weight(.bold))
            .tracking(0.6)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(Color.red.opacity(0.4), lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture(count: 3) { model.simulateFall() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Status. Triple tap to simulate a fall.")
            .accessibilityAction(named: "Simulate fall") { model.simulateFall() }
    }

    private func readinessPill(_ label: String, ok: Bool) -> some View {
        Text("\(label): \(ok ? "on" : "off")")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ok ? Color.green.opacity(0.15) : Color.orange.opacity(0.2))
            .clipShape(Capsule())
    }

    private var incidentStrip: some View {
        Group {
            if let card = model.incident {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(card.personName) · \(card.room) · \(card.severity.rawValue)")
                        .font(.subheadline.weight(.semibold))
                    Text("\(card.mechanism) · landed \(card.direction) · hit \(card.impact.isEmpty ? "unknown" : card.impact.joined(separator: ", "))")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Possible hurt: \(card.hurt.isEmpty ? (card.impact.isEmpty ? "unknown" : card.impact.joined(separator: ", ")) : card.hurt.joined(separator: ", ")) · \(card.severity.rawValue)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if !card.hurtNote.isEmpty {
                        Text(card.hurtNote)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Down \(card.timeDownSec)s · \(card.responsive ? "responsive" : "no reply") · \(card.address)")
                        .font(.caption)
                    if let banner = card.call911Banner {
                        Text(banner).font(.caption.weight(.bold)).foregroundStyle(.red)
                    } else if card.cleared {
                        Text("Cleared — family check-in note")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

struct HubButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var background: Color {
        switch kind {
        case .primary: Color.primary
        case .secondary: Color.primary.opacity(0.08)
        case .danger: Color.red.opacity(0.16)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(uiColor: .systemBackground)
        case .secondary: Color.primary
        case .danger: Color.red
        }
    }
}
