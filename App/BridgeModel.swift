import Foundation
import SwiftUI
import MeeABridgeCore

@MainActor final class BridgeModel: ObservableObject {
    @Published var serverURL = ""
    @Published var token = ""
    @Published var configured = false
    @Published var question = ""
    @Published var answer = ""
    @Published var message = ""
    @Published var busy = false
    @Published var snapshot: StepsSnapshot?
    @Published var syncConfirmed = false
    private let health = HealthReader()
    private var savedServerURL = ""
    var canSend: Bool { configured && token.isEmpty && serverURL == savedServerURL }
    init() {
        if let config = try? Credentials.load() {
            serverURL = config.baseURL.absoluteString; savedServerURL = serverURL; configured = true
        }
    }
    func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; message = ""
        defer { busy = false }
        do { try await operation() } catch { message = ResponsePolicy.safe(error).localizedDescription }
    }
    func save() async { await run {
        let existing = try? Credentials.load()
        let updated = try BackendConfiguration.updating(url: serverURL, token: token, previous: existing)
        try Credentials.save(url: updated.baseURL.absoluteString, token: updated.token)
        serverURL = try Credentials.load().baseURL.absoluteString; savedServerURL = serverURL
        token = ""; configured = true; snapshot = nil; syncConfirmed = false
        message = "Connection saved on this device."
    } }
    func disconnect() async { await run {
        try Credentials.clear(); configured = false; serverURL = ""; savedServerURL = ""; token = ""; answer = ""
        snapshot = nil; syncConfirmed = false; message = "Connection removed. Saved Manor imports remain on your PC."
    } }
    func test() async { await run {
        _ = try await MeeAClient(configuration: Credentials.load()).health()
        message = "Server reachable. Asking MeeA will also verify the token and agent."
    } }
    func ask() async { await run {
        answer = ""
        answer = try await MeeAClient(configuration: Credentials.load()).ask(question).answer
    } }
    func authorize() async { await run {
        try await health.requestAccess()
        message = "Permission request finished. Preview to see available steps. Manage access in Apple Health."
    } }
    func preview() async { await run {
        snapshot = try await health.preview(); syncConfirmed = false
        message = "Preview only. Tap Sync Health to send these seven completed days to your saved server."
    } }
    func sync() async { await run {
        guard let snapshot else { return }
        let receipt = try await MeeAClient(configuration: Credentials.load()).syncSteps(snapshot)
        syncConfirmed = true
        message = "Confirmed on MeeA: \(receipt.storedDays) days with readings (\(receipt.status)). Saved source: \(receipt.path)"
    } }
}
