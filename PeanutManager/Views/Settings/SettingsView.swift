import SwiftUI
import LineupAI

struct SettingsView: View {
    @State private var apiKey = Keychain.apiKey
    @State private var testResult: String?
    @State private var testing = false
    @AppStorage(AppSettings.lineupModelKey) private var lineupModel = ""

    var body: some View {
        Form {
            Section {
                SecureField("Key", text: $apiKey, prompt: Text("sk-or-…"))
                    .onSubmit(save)
                HStack {
                    Button("Save") { save() }
                    Button("Test Key") { test() }.disabled(apiKey.isEmpty || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("OpenRouter")
            } footer: {
                Link("Get a key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
            }

            Section {
                TextField("Lineups", text: $lineupModel, prompt: Text(OpenRouterClient.defaultLineupModel))
                Menu("Suggestions") {
                    ForEach(["anthropic/claude-sonnet-5.5", "anthropic/claude-opus-5.5", "openai/gpt-5.6-sol", "google/gemini-3.8-flash"], id: \.self) { slug in
                        Button(slug) { lineupModel = slug }
                    }
                    Divider()
                    Button("Use Default") { lineupModel = "" }
                }
                .fixedSize()
            } header: {
                Text("Model")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    private func save() {
        Keychain.apiKey = apiKey
        testResult = "Saved"
    }

    private func test() {
        save()
        testing = true
        testResult = nil
        Task {
            do {
                try await OpenRouterClient(apiKey: apiKey).verifyKey()
                testResult = "Works"
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}
