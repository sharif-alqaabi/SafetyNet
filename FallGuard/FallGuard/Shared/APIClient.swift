import Foundation

struct NotifyRequest: Codable {
    var incidentId: String
    var severity: String
    var summary: String
    var stillOnFloor: Bool
    var urgency: String
    var clipURL: String?
    var liveURL: String?
}

struct CallRequest: Codable {
    var incidentId: String
    var toRole: String
    var spokenScript: String
    var patchAfterSay: Bool
}

struct ConferenceRequest: Codable {
    var incidentId: String
}

struct ClipUploadResponse: Codable {
    var url: String
}

struct FamilyInboxItem: Codable, Identifiable {
    var id: String
    var text: String
    var incidentId: String
}

struct CallResponse: Codable {
    var sid: String?
    var to: String
    var role: String
}

final class APIClient: @unchecked Sendable {
    var baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8787")!) {
        self.baseURL = baseURL
    }

    func health() async throws {
        var request = URLRequest(url: baseURL.appending(path: "/health"))
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfNeeded(response, data: data)
    }

    func upsertIncident(_ incident: Incident) async throws -> Incident {
        try await post("/incidents", body: incident)
    }

    func fetchIncident(id: String) async throws -> Incident {
        try await get("/incidents/\(id)")
    }

    func latestIncident(homeCode: String) async throws -> Incident? {
        struct Envelope: Codable { var incident: Incident? }
        let env: Envelope = try await get("/homes/\(homeCode)/latest")
        return env.incident
    }

    func fetchFamilyInbox(homeCode: String, incidentId: String? = nil) async throws -> [FamilyInboxItem] {
        struct Envelope: Codable { var messages: [FamilyInboxItem] }
        var components = URLComponents(url: baseURL.appending(path: "/homes/\(homeCode)/inbox"), resolvingAgainstBaseURL: false)!
        if let incidentId, !incidentId.isEmpty {
            components.queryItems = [URLQueryItem(name: "incident", value: incidentId)]
        }
        guard let url = components.url else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.throwIfNeeded(response, data: data)
        return try JSONDecoder.fallGuard.decode(Envelope.self, from: data).messages
    }

    func ackFamilyInbox(homeCode: String, ids: [String]) async throws {
        struct Body: Codable { var ids: [String] }
        let _: [String: String] = try await post("/homes/\(homeCode)/inbox/ack", body: Body(ids: ids))
    }

    func notifyFamily(_ request: NotifyRequest) async throws {
        var requestURL = URLRequest(url: baseURL.appending(path: "/notify"))
        requestURL.httpMethod = "POST"
        requestURL.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requestURL.httpBody = try JSONEncoder.fallGuard.encode(request)
        let (data, response) = try await URLSession.shared.data(for: requestURL)
        try Self.throwIfNeeded(response, data: data)
    }

    func placeCall(_ request: CallRequest) async throws -> CallResponse {
        try await post("/call", body: request)
    }

    func connectFamilyAudio(incidentId: String) async throws {
        let _: [String: String] = try await post("/conference", body: ConferenceRequest(incidentId: incidentId))
    }

    func uploadClip(incidentId: String, jpegFrames: [Data]) async throws -> String {
        var parts: [String] = []
        let boundary = "FallGuard\(UUID().uuidString)"
        var body = Data()
        for (index, frame) in jpegFrames.enumerated() {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"frames\"; filename=\"frame-\(index).jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(frame)
            body.append("\r\n".data(using: .utf8)!)
            parts.append("frame-\(index).jpg")
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"incidentId\"\r\n\r\n".data(using: .utf8)!)
        body.append(incidentId.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: baseURL.appending(path: "/clips"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfNeeded(response, data: data)
        return try JSONDecoder.fallGuard.decode(ClipUploadResponse.self, from: data).url
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: path))
        try Self.throwIfNeeded(response, data: data)
        return try JSONDecoder.fallGuard.decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.fallGuard.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfNeeded(response, data: data)
        if data.isEmpty, T.self == Dictionary<String, String>.self {
            return ["ok": "true"] as! T
        }
        return try JSONDecoder.fallGuard.decode(T.self, from: data)
    }

    private static func throwIfNeeded(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "request failed"
            throw APIError.http(text)
        }
    }
}

enum APIError: LocalizedError {
    case http(String)
    var errorDescription: String? {
        switch self {
        case .http(let message): return message
        }
    }
}

extension JSONEncoder {
    static let fallGuard: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}

extension JSONDecoder {
    static let fallGuard: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
