import Foundation

struct FallSighting: Equatable {
    var reason: String
    var mechanism: String
    var direction: String
    var impact: [String]
    var hurt: [String]
    var severity: IncidentSeverity
    var hurtNote: String
    var room: String

    var brief: String {
        let hits = impact.isEmpty ? "unknown" : impact.joined(separator: ", ")
        let sites = hurt.isEmpty ? hits : hurt.joined(separator: ", ")
        let note = hurtNote.isEmpty ? "" : " \(hurtNote)"
        return "Looks like a \(mechanism). Landed \(direction). Hit: \(hits). Possible hurt: \(sites). Severity: \(severity.rawValue).\(note)"
    }

    /// Fills missing visual fields from the reason text and a pose-based first guess.
    func guessed() -> FallSighting {
        var out = self
        let blob = [reason, hurtNote, mechanism, direction, impact.joined(separator: " "), hurt.joined(separator: " ")]
            .joined(separator: " ")
            .lowercased()

        if Self.isBlank(out.direction) {
            if blob.contains("left") { out.direction = "left" }
            else if blob.contains("right") { out.direction = "right" }
            else if blob.contains("prone") || blob.contains("face down") || blob.contains("front") { out.direction = "front" }
            else if blob.contains("supine") || blob.contains("face up") || blob.contains("back") { out.direction = "back" }
            else { out.direction = "back" }
        }
        if Self.isBlank(out.mechanism) {
            if blob.contains("slip") { out.mechanism = "slip" }
            else if blob.contains("trip") { out.mechanism = "trip" }
            else if blob.contains("sit") { out.mechanism = "sit-to-floor" }
            else { out.mechanism = "collapse" }
        }
        if out.impact.isEmpty || out.impact.allSatisfy(Self.isBlank) {
            out.impact = Self.defaultHits(for: out.direction)
        }
        if out.hurt.isEmpty || out.hurt.allSatisfy(Self.isBlank) {
            out.hurt = out.impact
        }
        if out.hurtNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.hurtNote = "Guess from pose: landed \(out.direction), possible \(out.hurt.joined(separator: ", "))."
        }
        return out
    }

    private static func isBlank(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || trimmed == "unknown" || trimmed == "n/a" || trimmed == "none"
    }

    private static func defaultHits(for direction: String) -> [String] {
        switch direction.lowercased() {
        case "left": return ["left hip", "left shoulder", "left arm"]
        case "right": return ["right hip", "right shoulder", "right arm"]
        case "front": return ["knees", "wrists", "face"]
        default: return ["back", "hips", "head"]
        }
    }
}

enum IncidentSeverity: String, Codable, CaseIterable {
    case low
    case moderate
    case high
    case critical

    static func parse(_ raw: String?) -> IncidentSeverity? {
        guard let raw else { return nil }
        return IncidentSeverity(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct Incident: Codable, Equatable, Identifiable {
    var id: String
    var homeCode: String
    var mechanism: String
    var direction: String
    var impact: [String]
    var hurt: [String]
    var hurtNote: String
    var room: String
    var timeDownSec: Int
    var responsive: Bool
    var ableToMove: Bool?
    var severity: IncidentSeverity
    var address: String
    var notes: String
    var personName: String
    var clipURL: String?
    var liveURL: String?
    var recommend911: Bool
    var asksAmbulance: Bool
    var cleared: Bool
    var familyNotified: Bool
    var familyAnswered: Bool
    var familyPatched: Bool
    var emergencyDemoCalled: Bool
    var createdAt: Date
    var updatedAt: Date

    var call911Banner: String? {
        guard recommend911 || emergencyDemoCalled else { return nil }
        return "Call 911 — \(address)"
    }

    static func draft(profile: HomeProfile) -> Incident {
        let now = Date()
        return Incident(
            id: UUID().uuidString,
            homeCode: profile.homeCode,
            mechanism: "unknown",
            direction: "unknown",
            impact: [],
            hurt: [],
            hurtNote: "",
            room: profile.room,
            timeDownSec: 0,
            responsive: false,
            ableToMove: nil,
            severity: .high,
            address: profile.address,
            notes: "",
            personName: profile.personName,
            clipURL: nil,
            liveURL: nil,
            recommend911: false,
            asksAmbulance: false,
            cleared: false,
            familyNotified: false,
            familyAnswered: false,
            familyPatched: false,
            emergencyDemoCalled: false,
            createdAt: now,
            updatedAt: now
        )
    }
}
