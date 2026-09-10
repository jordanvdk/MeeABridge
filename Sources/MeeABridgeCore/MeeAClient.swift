import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor MeeAClient {
    private let configuration: BackendConfiguration
    private let session: URLSession
    public init(configuration: BackendConfiguration) {
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 23
        settings.timeoutIntervalForResource = 25
        settings.waitsForConnectivity = false
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        settings.urlCredentialStorage = nil
        self.session = URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func health() async throws -> HealthResponse {
        let value: HealthResponse = try await request("v1/health", method: "GET")
        guard value.status == "ok", value.service == "meea" else { throw BridgeError.invalidResponse }
        return value
    }
    public func ask(_ question: String, source: String = "manual") async throws -> AskResponse {
        let body = try RequestBodyPolicy.encode(AskRequest(question: question, source: source))
        let response: AskResponse = try await request("v1/ask", method: "POST", body: body)
        guard response.error == nil else { throw BridgeError.agent }
        guard !response.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.answer.utf8.count <= 32768 else { throw BridgeError.invalidResponse }
        return response
    }
    public func syncSteps(_ snapshot: StepsSnapshot) async throws -> ImportReceipt {
        let body = try RequestBodyPolicy.encode(snapshot, using: StepsSnapshot.encoder())
        let response: ImportReceipt = try await request("v1/imports/apple-health/steps", method: "POST", body: body, healthImport: true)
        guard response.importID == snapshot.importID, ["stored", "unchanged"].contains(response.status),
              response.storedDays == snapshot.days.filter({ $0.count != nil }).count,
              response.path == "hearth/import-apple-health-steps-\(snapshot.importID.uuidString.lowercased()).json",
              response.hash.count == 64, response.hash.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw BridgeError.invalidResponse }
        return response
    }
    private func request<T: Decodable>(_ path: String, method: String, body: Data? = nil, healthImport: Bool = false) async throws -> T {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw BridgeError.invalidResponse }
            try ResponsePolicy.check(http.statusCode, healthImport: healthImport)
            guard http.mimeType == "application/json" else { throw BridgeError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 128 * 1024 else { throw BridgeError.invalidResponse }
                data.append(byte)
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let safe = ResponsePolicy.safe(error)
            if healthImport && ![BridgeError.credentials, .unsupportedImport, .configuration].contains(safe) {
                throw BridgeError.importFailed
            }
            throw safe
        }
    }
}
