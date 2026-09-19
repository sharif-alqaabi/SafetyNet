import Foundation
import FirebaseAILogic
import FirebaseCore

struct DeskHandoff: Sendable {
    var trigger: String
    var profile: HomeProfile
    var sighting: FallSighting?
    var incident: Incident
    var heard: [String]
    var spoken: [String]
    var situationNote: String
    var silent: Bool
    var victimSpoke: Bool
    var timeDownSec: Int
    var watchingClip: Bool
}

struct DeskDecision: Codable, Sendable {
    var mechanism: String?
    var direction: String?
    var impact: [String]?
    var hurt: [String]?
    var hurtNote: String?
    var severity: String?
    var responsive: Bool?
    var ableToMove: Bool?
    var stillOnFloor: Bool?
    var recommend911: Bool?
    var asksAmbulance: Bool?
    var cleared: Bool?
    var notify: String?
    var familySummary: String?
    var notes: String?
}

enum DeskAgent {
    static let preferred = "gemini-2.5-flash"
    static let fallback = "gemini-2.0-flash"

    static func decide(_ handoff: DeskHandoff) async throws -> DeskDecision {
        if FirebaseApp.app() == nil,
           Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
        do {
            return try await decide(handoff, model: preferred)
        } catch {
            return try await decide(handoff, model: fallback)
        }
    }

    private static func decide(_ handoff: DeskHandoff, model: String) async throws -> DeskDecision {
        let generative = FirebaseAI.firebaseAI(backend: .googleAI()).generativeModel(
            modelName: model,
            generationConfig: GenerationConfig(
                temperature: 0.2,
                responseMIMEType: "application/json",
                responseSchema: schema
            ),
            systemInstruction: ModelContent(role: "system", parts: systemText)
        )
        let response = try await generative.generateContent(userText(handoff))
        let raw = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let json = stripFences(raw)
        guard let data = json.data(using: .utf8) else {
            throw APIError.http("Desk agent returned empty JSON")
        }
        return try JSONDecoder.fallGuard.decode(DeskDecision.self, from: data)
    }

    private static func stripFences(_ text: String) -> String {
        var out = text
        if out.hasPrefix("```") {
            out = out.replacingOccurrences(of: "```json", with: "")
            out = out.replacingOccurrences(of: "```", with: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let schema = Schema.object(
        properties: [
            "mechanism": .string(description: "trip, slip, collapse, sit-to-floor, or unknown"),
            "direction": .string(description: "left, right, back, front, or unknown"),
            "impact": .array(items: .string(), description: "Body areas that likely hit"),
            "hurt": .array(items: .string(), description: "Possible injury sites"),
            "hurt_note": .string(description: "One sentence working picture"),
            "severity": .string(description: "low | moderate | high | critical"),
            "responsive": .boolean(description: "Whether they answered"),
            "able_to_move": .boolean(description: "Whether they can move"),
            "still_on_floor": .boolean(description: "Whether they are still down"),
            "recommend_911": .boolean(description: "True for skip-rung / critical"),
            "asks_ambulance": .boolean(description: "True if they asked for 911"),
            "cleared": .boolean(description: "True only after a safe chair sit"),
            "notify": .string(description: "urgent | resolved | none"),
            "family_summary": .string(description: "One or two sentences for iMessage"),
            "notes": .string(description: "Short desk notes")
        ]
    )

    private static let systemText = """
        You are FallGuard desk. You never speak to the person on the floor.
        Live Gemini stays on that call. You write the incident card and decide the family iMessage.
        Working picture only — not a diagnosis. Do not name fractures.
        notify=urgent if they are silent, in pain, cannot get up, struggling, head/hip concern, or time down is 12s or more without a safe chair sit.
        notify=resolved only after they sat in a chair and said they are unhurt.
        notify=none only if they just started answering and time down is under 12s.
        For a silent test clip, use urgent.
        family_summary is the iMessage: who, where, hurt guess, still on floor. Short.
        """

    private static func userText(_ handoff: DeskHandoff) -> String {
        let seen = handoff.sighting
        let heard = handoff.heard.isEmpty ? "(none)" : handoff.heard.suffix(8).joined(separator: " | ")
        let spoken = handoff.spoken.isEmpty ? "(none)" : handoff.spoken.suffix(8).joined(separator: " | ")
        return """
        Trigger: \(handoff.trigger)
        Person: \(handoff.profile.personName)
        Address: \(handoff.profile.address)
        Room: \(handoff.profile.room)
        Family: \(handoff.profile.contactName)
        Time down: \(handoff.timeDownSec)s
        Silent: \(handoff.silent)
        Victim spoke: \(handoff.victimSpoke)
        Test clip: \(handoff.watchingClip)
        Camera: \(seen?.brief ?? "no sighting yet")
        Camera reason: \(seen?.reason ?? "")
        Live situation: \(handoff.situationNote.isEmpty ? "(none)" : handoff.situationNote)
        What they said: \(heard)
        What Live said: \(spoken)
        Card so far: mechanism=\(handoff.incident.mechanism) direction=\(handoff.incident.direction) severity=\(handoff.incident.severity.rawValue) notes=\(handoff.incident.notes)
        Write the card and choose notify.
        """
    }
}
