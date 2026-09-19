import AVFoundation
import Foundation

@MainActor
final class TalkService: ObservableObject {
    @Published var isTalking = false
    @Published var status = "Talk idle"

    private let api = APIClient()

    func start(incidentId: String, baseURL: URL) async {
        let client = APIClient(baseURL: baseURL)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            try await client.connectFamilyAudio(incidentId: incidentId)
            isTalking = true
            status = "Joined hub conference"
        } catch {
            status = error.localizedDescription
        }
    }

    func stop() {
        isTalking = false
        status = "Talk idle"
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
