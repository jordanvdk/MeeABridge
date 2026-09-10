import Foundation
import AppIntents
import MeeABridgeCore

struct AskMeeAIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask MeeA"
    static var description = IntentDescription("Ask your configured MeeA server a question.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Question") var question: String
    static var parameterSummary: some ParameterSummary { Summary("Ask MeeA \(\.$question)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let response = try await MeeAClient(configuration: Credentials.load()).ask(question, source: "siri")
            return .result(value: response.answer, dialog: IntentDialog(stringLiteral: response.answer))
        } catch {
            let message = ResponsePolicy.safe(error).localizedDescription
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
    }
}
struct MeeAShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskMeeAIntent(), phrases: ["Ask \(.applicationName)"],
                    shortTitle: "Ask MeeA", systemImageName: "bubble.left.and.bubble.right")
    }
}
