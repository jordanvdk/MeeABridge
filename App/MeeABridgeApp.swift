import SwiftUI

@MainActor @main struct MeeABridgeApp: App {
    @StateObject private var model = BridgeModel()
    var body: some Scene { WindowGroup { ContentView(model: model) } }
}

@MainActor struct ContentView: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("https://your-server.example.invalid", text: $model.serverURL)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(model.configured ? "Token (required for a new server)" : "API token", text: $model.token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save connection") { Task { await model.save() } }
                    if model.configured {
                        Button("Test connection") { Task { await model.test() } }.disabled(!model.canSend)
                        Button("Remove connection", role: .destructive) { Task { await model.disconnect() } }
                    }
                    if model.configured && !model.canSend { Text("Save connection changes before sending.").font(.footnote) }
                    Text("Use your private HTTPS address. The token stays in this device’s Keychain. Leave it blank to keep it for the same server; enter it again when changing servers.").font(.footnote)
                }
                Section("Ask MeeA") {
                    TextField("Your question", text: $model.question, axis: .vertical).lineLimit(2...6)
                    Button("Ask") { Task { await model.ask() } }.disabled(!model.canSend || model.question.isEmpty)
                    if !model.answer.isEmpty { Text(model.answer).textSelection(.enabled) }
                    Text("For Siri, add Ask MeeA in Shortcuts. Your device must be unlocked. A timed-out question may still run on your PC.").font(.footnote)
                }
                Section("Apple Health · steps") {
                    Button("Request read access") { Task { await model.authorize() } }
                    Button("Preview last 7 completed days") { Task { await model.preview() } }
                    if let snapshot = model.snapshot {
                        Text(snapshot.timeZone).font(.caption)
                        ForEach(snapshot.days) { day in
                            LabeledContent(day.day, value: day.count.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "Unavailable")
                        }
                        Button(model.syncConfirmed ? "Saved · verify same import" : "Sync Health / retry preview") { Task { await model.sync() } }
                            .disabled(!model.canSend || snapshot.days.allSatisfy { $0.count == nil })
                    }
                    Text("Read-only steps. Nothing uploads until you tap Sync Health. Unavailable can mean no readings or denied access; it is never treated as zero. Retrying this preview reuses its import ID. A new preview creates a new snapshot.").font(.footnote)
                }
                if model.busy { ProgressView("Working…") }
                if !model.message.isEmpty { Section { Text(model.message).accessibilityAddTraits(.updatesFrequently) } }
            }
            .disabled(model.busy)
            .navigationTitle("MeeA Bridge")
            .privacySensitive()
        }
        .overlay { if scenePhase != .active { Color(.systemBackground).ignoresSafeArea().overlay(Text("MeeA Bridge")) } }
    }
}
