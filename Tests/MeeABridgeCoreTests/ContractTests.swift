import XCTest
@testable import MeeABridgeCore

final class ContractTests: XCTestCase {
    private var token: String { String(repeating: "x", count: 43) } // Synthetic, never a usable credential.
    func testBackendRejectsCredentialsQueriesFragmentsAndRemoteCleartext() throws {
        for url in ["http://example.invalid", "https://user:pass@example.invalid", "https://example.invalid/path",
                    "https://example.invalid?secret=value", "https://example.invalid#fragment", "file:///tmp/file"] {
            XCTAssertThrowsError(try BackendConfiguration(url: url, token: token, allowLoopbackHTTP: true))
        }
        _ = try BackendConfiguration(url: "https://example.invalid", token: token)
        _ = try BackendConfiguration(url: "http://127.0.0.1:8765", token: token, allowLoopbackHTTP: true)
        XCTAssertThrowsError(try BackendConfiguration(url: "http://127.0.0.1:8765", token: token))
        XCTAssertThrowsError(try BackendConfiguration(url: "https://example.invalid", token: "short"))
    }
    func testSavedTokenCannotFollowAChangedOrigin() throws {
        let saved = try BackendConfiguration(url: "https://example.invalid", token: token)
        for url in ["https://example.invalid/", "https://EXAMPLE.invalid:443"] {
            XCTAssertEqual(try BackendConfiguration.updating(url: url, token: "", previous: saved).token, token)
        }
        for url in ["https://other.invalid", "https://example.invalid:8443"] {
            XCTAssertThrowsError(try BackendConfiguration.updating(url: url, token: "", previous: saved)) {
                XCTAssertEqual($0 as? BridgeError, .newServerCredentials)
            }
        }
        let replacement = String(repeating: "y", count: 43)
        XCTAssertEqual(try BackendConfiguration.updating(url: "https://other.invalid", token: replacement, previous: saved).token, replacement)
        XCTAssertThrowsError(try BackendConfiguration.updating(url: "https://example.invalid", token: "", previous: nil))
        XCTAssertThrowsError(try BackendConfiguration.updating(url: "http://example.invalid", token: "", previous: saved))
    }
    func testEncodedBodyLimitIncludesEscapingAndEnvelope() throws {
        _ = try RequestBodyPolicy.encode(AskRequest(question: String(repeating: "a", count: 8192)))
        let escaped = try AskRequest(question: "prefix" + String(repeating: "\u{0001}", count: 3000))
        XCTAssertGreaterThan(try JSONEncoder().encode(escaped).count, RequestBodyPolicy.maxBytes)
        XCTAssertThrowsError(try RequestBodyPolicy.encode(escaped)) { XCTAssertEqual($0 as? BridgeError, .requestTooLarge) }
        XCTAssertEqual(try RequestBodyPolicy.encode(String(repeating: "a", count: 16382)).count, 16384)
        XCTAssertThrowsError(try RequestBodyPolicy.encode(String(repeating: "a", count: 16383))) {
            XCTAssertEqual($0 as? BridgeError, .requestTooLarge)
        }
    }
    func testQuestionBytesAndStableNullContinuation() throws {
        XCTAssertThrowsError(try AskRequest(question: "   "))
        XCTAssertThrowsError(try AskRequest(question: String(repeating: "🦊", count: 2049)))
        XCTAssertThrowsError(try AskRequest(question: "hello", source: "tool"))
        let data = try JSONEncoder().encode(AskRequest(question: " hello ", source: "siri"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["question"] as? String, "hello")
        XCTAssertTrue(json["conversation_id"] is NSNull)
        XCTAssertEqual(Set(json.keys), ["question", "source", "conversation_id"])
    }
    func testSafeErrorsNeverForwardServerText() {
        XCTAssertEqual(ResponsePolicy.safe(URLError(.timedOut)), .timeout)
        XCTAssertEqual(ResponsePolicy.safe(URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(ResponsePolicy.safe(NSError(domain: "synthetic private body", code: 1)), .agent)
        XCTAssertThrowsError(try ResponsePolicy.check(401)) { XCTAssertEqual($0 as? BridgeError, .credentials) }
        XCTAssertThrowsError(try ResponsePolicy.check(404, healthImport: true)) { XCTAssertEqual($0 as? BridgeError, .unsupportedImport) }
        XCTAssertThrowsError(try ResponsePolicy.check(302))
    }
    func testStepsSnapshotPreservesMissingAsNullAndStableRetryIdentity() throws {
        let start = Date(timeIntervalSince1970: 1_735_689_600)
        let day = StepsDay(day: "2025-01-01", start: start, end: start.addingTimeInterval(86400), count: nil)
        let snapshot = try StepsSnapshot(days: [day], timeZone: "UTC", capturedAt: start.addingTimeInterval(86400))
        let first = try StepsSnapshot.encoder().encode(snapshot)
        XCTAssertEqual(first, try StepsSnapshot.encoder().encode(snapshot))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        let rows = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertTrue(rows[0]["count"] is NSNull)
        XCTAssertThrowsError(try StepsSnapshot(days: [day, day], timeZone: "UTC"))
        XCTAssertThrowsError(try StepsSnapshot(days: [day], timeZone: "Not/AZone"))
        XCTAssertThrowsError(try StepsSnapshot(days: [StepsDay(day: "2025-01-01", start: start, end: start.addingTimeInterval(86400), count: -.infinity)], timeZone: "UTC"))
    }
    func testCivilDayValidationIncludesDSTAndRejectsMislabeledOrGappedDays() throws {
        let parse = ISO8601DateFormatter()
        let start = try XCTUnwrap(parse.date(from: "2025-03-09T08:00:00Z"))
        let end = try XCTUnwrap(parse.date(from: "2025-03-10T07:00:00Z"))
        let day = StepsDay(day: "2025-03-09", start: start, end: end, count: 0)
        _ = try StepsSnapshot(days: [day], timeZone: "America/Los_Angeles", capturedAt: end)
        XCTAssertThrowsError(try StepsSnapshot(days: [day], timeZone: "UTC", capturedAt: end))
        XCTAssertThrowsError(try StepsSnapshot(days: [day], timeZone: "America/Los_Angeles", capturedAt: start))
        let wrongEnd = StepsDay(day: day.day, start: start, end: start.addingTimeInterval(86400), count: 1)
        XCTAssertThrowsError(try StepsSnapshot(days: [wrongEnd], timeZone: "America/Los_Angeles", capturedAt: end.addingTimeInterval(86400)))
        let mislabeled = StepsDay(day: "2025-02-30", start: start, end: end, count: 1)
        XCTAssertThrowsError(try StepsSnapshot(days: [mislabeled], timeZone: "America/Los_Angeles", capturedAt: end))
    }
}
