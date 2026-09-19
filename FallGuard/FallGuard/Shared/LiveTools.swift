import Foundation
import FirebaseAILogic

enum LiveTools {
    static var allDeclarations: [Tool] { watchDeclarations }

    static var watchDeclarations: [Tool] {
        [
            Tool.functionDeclarations([
                FunctionDeclaration(
                    name: "watch_update",
                    description: "WATCH: call on every LOOK. Set fallen=true only if a person is on the floor right now.",
                    parameters: [
                        "fallen": Schema.boolean(description: "True if a person is on the floor"),
                        "person_visible": Schema.boolean(description: "True if a person is in frame"),
                        "reason": Schema.string(description: "What you see plus your landing guess"),
                        "mechanism": Schema.string(description: "Required guess: trip, slip, collapse, or sit-to-floor. Already down with no trip visible → collapse. Not unknown if a person is visible."),
                        "direction": Schema.string(description: "Required guess: left, right, back, or front from which side of the body is on the floor. Not unknown if a person is visible."),
                        "impact": Schema.array(
                            items: Schema.string(),
                            description: "Required guess of body areas that likely hit, e.g. left hip, left shoulder, head. Infer from pose."
                        ),
                        "hurt": Schema.array(
                            items: Schema.string(),
                            description: "Required guess of possible injury sites from that landing — working picture, not a diagnosis"
                        ),
                        "severity": Schema.string(description: "Required visual guess: low | moderate | high | critical"),
                        "hurt_note": Schema.string(description: "Required one-sentence guess, e.g. Looks left-side down, possible left hip and shoulder."),
                        "room": Schema.string(description: "Room if you can tell")
                    ],
                    optionalParameters: ["room"]
                ),
                FunctionDeclaration(
                    name: "situation",
                    description: "COACH: pass facts to the desk agent. Call after they answer, or if they stay silent. Desk writes the incident and texts family. Keep talking. Do not wait.",
                    parameters: [
                        "heard": Schema.string(description: "What they said, or empty if silent"),
                        "hurting": Schema.string(description: "Where they said they hurt, or empty"),
                        "silent": Schema.boolean(description: "True if they have not answered"),
                        "still_on_floor": Schema.boolean(description: "True if they are still down"),
                        "struggling": Schema.boolean(description: "True if they are trying and failing to get up"),
                        "can_move": Schema.boolean(description: "Whether they can move"),
                        "wants_chair": Schema.boolean(description: "Whether they want to get to a chair"),
                        "ending": Schema.string(description: "stay_down | chair | unknown"),
                        "note": Schema.string(description: "One sentence for the desk: who, hurt, still down")
                    ],
                    optionalParameters: ["heard", "hurting", "can_move", "wants_chair", "ending", "struggling"]
                )
            ])
        ]
    }
}

struct ToolCallEnvelope: Sendable {
    var id: String
    var name: String
    var args: JSONObject

    func string(_ key: String) -> String? {
        guard let value = args[key] else { return nil }
        if case .string(let text) = value { return text }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        guard let value = args[key] else { return nil }
        if case .bool(let flag) = value { return flag }
        if case .string(let text) = value { return NSString(string: text).boolValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        guard let value = args[key] else { return nil }
        if case .number(let number) = value { return Int(number) }
        if case .string(let text) = value { return Int(text) }
        return nil
    }

    func strings(_ key: String) -> [String] {
        guard let value = args[key] else { return [] }
        if case .array(let items) = value {
            return items.compactMap {
                if case .string(let text) = $0 { return text }
                return nil
            }
        }
        if case .string(let text) = value { return [text] }
        return []
    }
}

enum JSONBridge {
    static func object(_ dictionary: [String: Any]) -> JSONObject {
        dictionary.reduce(into: JSONObject()) { partial, item in
            partial[item.key] = value(item.value)
        }
    }

    static func value(_ any: Any) -> JSONValue {
        switch any {
        case let value as Bool: return .bool(value)
        case let value as Int: return .number(Double(value))
        case let value as Double: return .number(value)
        case let value as String: return .string(value)
        case let value as [String]: return .array(value.map { .string($0) })
        case let value as [String: Any]: return .object(object(value))
        default: return .string(String(describing: any))
        }
    }
}
