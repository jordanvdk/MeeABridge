import Foundation

public enum BridgeError: Error, LocalizedError, Equatable {
    case configuration, credentials, newServerCredentials, requestTooLarge, invalidQuestion, unreachable, timeout, busy, agent, invalidResponse, healthUnavailable, unsupportedImport, importFailed
    public var errorDescription: String? {
        switch self {
        case .configuration: return "Open MeeA Bridge and configure a valid HTTPS server URL."
        case .credentials: return "Open MeeA Bridge and check the API token."
        case .newServerCredentials: return "Enter the API token again when changing servers."
        case .requestTooLarge: return "The encoded request is too large. Shorten the question or create a smaller preview."
        case .invalidQuestion: return "Enter a question of at most 8192 UTF-8 bytes."
        case .unreachable: return "MeeA isn’t reachable right now. Check Tailscale and the PC."
        case .timeout: return "MeeA took too long to respond. The question may still be running."
        case .busy: return "MeeA is busy. Try again shortly."
        case .agent: return "MeeA encountered an error while answering that."
        case .invalidResponse: return "MeeA returned an unexpected response."
        case .healthUnavailable: return "Apple Health is unavailable on this device."
        case .importFailed: return "Health sync was not confirmed. Retry the same preview; it may already be saved."
        case .unsupportedImport: return "This MeeA server does not support Health imports yet."
        }
    }
}

public struct BackendConfiguration: Sendable {
    public let baseURL: URL
    public let token: String
    public static func updating(url: String, token: String, previous: BackendConfiguration?) throws -> BackendConfiguration {
        let candidate = try BackendConfiguration(url: url, token: token.isEmpty ? (previous?.token ?? "") : token)
        if token.isEmpty, let previous {
            guard candidate.baseURL.scheme?.lowercased() == previous.baseURL.scheme?.lowercased(),
                  candidate.baseURL.host?.lowercased() == previous.baseURL.host?.lowercased(),
                  (candidate.baseURL.port ?? 443) == (previous.baseURL.port ?? 443)
            else { throw BridgeError.newServerCredentials }
        }
        return candidate
    }
    public init(url: String, token: String, allowLoopbackHTTP: Bool = false) throws {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
              c.port == nil || (1...65535).contains(c.port!), let parsed = c.url,
              c.scheme == "https" || (allowLoopbackHTTP && c.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()))
        else { throw BridgeError.configuration }
        guard (43...256).contains(token.utf8.count), token.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "_" || $0 == "-"
        }) else { throw BridgeError.credentials }
        self.baseURL = parsed
        self.token = token
    }
}

public struct HealthResponse: Decodable, Sendable {
    public let status: String
    public let service: String
    public let version: String
}
public struct APIProblem: Codable, Sendable { public let code: String; public let message: String }
public struct AskResponse: Decodable, Sendable {
    public let answer: String
    public let conversationID: String?
    public let sources: [Source]
    public let error: APIProblem?
    public struct Source: Decodable, Sendable {}
    enum CodingKeys: String, CodingKey { case answer, sources, error; case conversationID = "conversation_id" }
}
public struct AskRequest: Encodable, Sendable {
    public let question: String
    public let source: String
    public init(question: String, source: String = "manual") throws {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, question.utf8.count <= 8192, ["manual", "siri"].contains(source) else { throw BridgeError.invalidQuestion }
        self.question = trimmed; self.source = source
    }
    enum CodingKeys: String, CodingKey { case question, source; case conversationID = "conversation_id" }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(question, forKey: .question); try c.encode(source, forKey: .source); try c.encodeNil(forKey: .conversationID)
    }
}

/// V0.5 aggregate snapshot, not a raw-sample feed or an incremental HealthKit anchor.
public struct StepsDay: Codable, Sendable, Equatable, Identifiable {
    public let day: String
    public let start: Date
    public let end: Date
    public let count: Double?
    public var id: String { day }
    enum CodingKeys: String, CodingKey { case day, start, end, count }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(day, forKey: .day); try c.encode(start, forKey: .start); try c.encode(end, forKey: .end)
        if let count { try c.encode(count, forKey: .count) } else { try c.encodeNil(forKey: .count) }
    }
    public init(day: String, start: Date, end: Date, count: Double?) {
        self.day = day; self.start = start; self.end = end; self.count = count
    }
}
public struct StepsSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let importID: UUID
    public let capturedAt: Date
    public let timeZone: String
    public let days: [StepsDay]
    enum CodingKeys: String, CodingKey {
        case days; case schemaVersion = "schema_version", importID = "import_id", capturedAt = "captured_at", timeZone = "time_zone"
    }
    public init(days: [StepsDay], timeZone: String, capturedAt: Date = Date(), importID: UUID = UUID()) throws {
        guard (1...7).contains(days.count), TimeZone(identifier: timeZone) != nil,
              Set(days.map(\.day)).count == days.count else { throw BridgeError.invalidResponse }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        guard capturedAt.timeIntervalSince1970.isFinite else { throw BridgeError.invalidResponse }
        for (index, day) in days.enumerated() {
            guard day.start.timeIntervalSince1970.isFinite, day.end.timeIntervalSince1970.isFinite,
                  formatter.string(from: day.start) == day.day,
                  calendar.startOfDay(for: day.start) == day.start,
                  calendar.date(byAdding: .day, value: 1, to: day.start) == day.end,
                  day.end <= capturedAt,
                  index == 0 || days[index - 1].end == day.start,
                  day.count == nil || (day.count!.isFinite && day.count! >= 0 && day.count! <= 200_000)
            else { throw BridgeError.invalidResponse }
        }
        self.schemaVersion = 1; self.importID = importID; self.capturedAt = capturedAt; self.timeZone = timeZone; self.days = days
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}
public struct ImportReceipt: Decodable, Sendable {
    public let importID: UUID
    public let status: String
    public let storedDays: Int
    public let path: String
    public let hash: String
    enum CodingKeys: String, CodingKey { case status, path, hash; case importID = "import_id", storedDays = "stored_days" }
}

public enum RequestBodyPolicy {
    public static let maxBytes = 16 * 1024
    public static func encode<T: Encodable>(_ value: T, using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let data = try encoder.encode(value)
        guard data.count <= maxBytes else { throw BridgeError.requestTooLarge }
        return data
    }
}

public enum ResponsePolicy {
    public static func check(_ status: Int, healthImport: Bool = false) throws {
        switch status {
        case 200...299: return
        case 401, 403: throw BridgeError.credentials
        case 408, 504: throw BridgeError.timeout
        case 429, 503: throw BridgeError.busy
        case 404 where healthImport: throw BridgeError.unsupportedImport
        default: throw BridgeError.agent
        }
    }
    public static func safe(_ error: Error) -> BridgeError {
        if let known = error as? BridgeError { return known }
        if let url = error as? URLError { return url.code == .timedOut ? .timeout : .unreachable }
        if error is DecodingError { return .invalidResponse }
        return .agent
    }
}
