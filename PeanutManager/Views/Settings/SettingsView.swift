import SwiftUI
import LineupAI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"
    @State private var ai = AIService.shared

    var body: some View {
        TabView(selection: $tab) {
            Tab("AI", systemImage: "sparkles", value: "general") { AISettings() }
            if ai.provider == .openRouter {
                Tab("OpenRouter Models", systemImage: "cpu", value: "models") { ModelSettings() }
            }
        }
        .scenePadding()
        .frame(width: 640, height: 640)
        .alert("You're using your ChatGPT plan", isPresented: $ai.showWelcome) {
            Button("Got It") {}
            Link("Manage Usage", destination: ChatGPTAuth.manageUsageURL)
        } message: {
            Text("Lineups and scouting reports in Peanut Manager use your ChatGPT plan. You can review and limit usage in ChatGPT settings.")
        }
    }
}

struct AISettings: View {
    @State private var ai = AIService.shared

    var body: some View {
        Form {
            Section {
                Picker("Run AI With", selection: $ai.provider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
            }
            switch ai.provider {
            case .chatGPT: ChatGPTSettings()
            case .openRouter: OpenRouterKeySettings()
            }
        }
        .formStyle(.grouped)
    }
}

/// Sign in with ChatGPT, the account, and which ChatGPT model runs.
struct ChatGPTSettings: View {
    @State private var ai = AIService.shared

    var body: some View {
        if ai.isSignedIn {
            Section {
                LabeledContent("Account", value: ai.account?.email ?? ai.account?.name ?? "ChatGPT")
                if ai.planUsageGranted {
                    LabeledContent("Billing", value: "Your ChatGPT plan")
                } else {
                    LabeledContent("Billing") {
                        HStack {
                            Text("Plan use is off").foregroundStyle(.secondary)
                            Button("Turn On") { ai.signIn(askConsent: true) }
                        }
                    }
                }
                HStack {
                    Link("Manage Usage", destination: ChatGPTAuth.manageUsageURL)
                    Spacer()
                    Button("Sign Out") { ai.signOut() }
                }
            }
            Section {
                Picker("Model", selection: $ai.chatGPTModelID) {
                    if ai.chatGPTModels.isEmpty { Text(ai.displayName(for: ai.chatGPTModelID)).tag(ai.chatGPTModelID) }
                    ForEach(ai.chatGPTModels) { Text($0.name).tag($0.id) }
                }
                Picker("Thinking", selection: $ai.reasoningEffort) {
                    Text("Default\(ai.currentModel?.defaultEffort.map { " (\($0.capitalized))" } ?? "")").tag(String?.none)
                    Divider()
                    ForEach(ai.effortChoices, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                }
            } footer: {
                if let error = ai.modelsError {
                    Text(error).foregroundStyle(.secondary)
                } else if let summary = ai.currentModel?.summary {
                    Text(summary).foregroundStyle(.secondary)
                }
            }
            .task { if ai.chatGPTModels.isEmpty { await ai.loadModels() } }
            if let error = ai.signInError {
                Section { Text(error).foregroundStyle(.secondary) }
            }
        } else {
            Section {
                VStack(spacing: 12) {
                    Text("Use Your ChatGPT Plan").font(.title3.weight(.semibold))
                    Text("Lineups and scouting reports run on your ChatGPT Plus or Pro plan. No API key needed.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if ai.isSigningIn {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                            Button("Cancel") { ai.cancelSignIn() }
                        }
                        .frame(height: 32)
                    } else {
                        ContinueWithChatGPTButton { ai.signIn() }
                    }
                    if let error = ai.signInError {
                        Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    if ai.account != nil && !ai.isSigningIn {
                        Button("Use a Different Account") { ai.useDifferentAccount() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
    }
}

/// OpenAI's sign-in button style: black, rounded, "Continue with ChatGPT".
struct ContinueWithChatGPTButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text("Continue with ChatGPT")
                .font(.body.weight(.medium))
                .padding(.horizontal, 22)
                .frame(height: 36)
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct OpenRouterKeySettings: View {
    @State private var apiKey = Keychain.apiKey
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section {
            SecureField("OpenRouter Key", text: $apiKey, prompt: Text("sk-or-…"))
                .onSubmit(save)
            HStack {
                Button("Save") { save() }
                Button("Test") { test() }.disabled(apiKey.isEmpty || testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult { Text(testResult).foregroundStyle(.secondary) }
                Spacer()
                Link("Get a key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
            }
        }
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

/// Pick which models appear in the app, from OpenRouter's full live catalog.
struct ModelSettings: View {
    @State private var library = ModelLibrary.shared
    @State private var catalog: [OpenRouterClient.ModelInfo] = []
    @State private var loadError: String?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("In the App").font(.headline)
                List {
                    ForEach(library.models) { model in
                        HStack {
                            Image(systemName: library.selectedID == model.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(library.selectedID == model.id ? Color.accentColor : .secondary)
                                .onTapGesture { library.selectedID = model.id }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.name)
                                Text(model.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let info = catalog.first(where: { $0.id == model.id }) { PriceText(info: info) }
                            Button { library.remove(model.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(library.models.count == 1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { library.selectedID = model.id }
                    }
                    .onMove { library.models.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered)
                .frame(height: 240)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("All OpenRouter Models").font(.headline)
                TextField("Search", text: $search, prompt: Text("Search \(catalog.isEmpty ? "" : "\(catalog.count) ")models"))
                    .textFieldStyle(.roundedBorder)
                List {
                    if let loadError {
                        Text(loadError).foregroundStyle(.secondary)
                    } else if catalog.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                    }
                    if !search.isEmpty && search.contains("/") && !catalog.contains(where: { $0.id == search }) {
                        Button("Add \"\(search)\"") { library.add(SavedModel(id: search, name: search)) }
                    }
                    ForEach(results) { info in
                        let added = library.models.contains { $0.id == info.id }
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name)
                                Text(info.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            PriceText(info: info)
                            Button {
                                library.add(SavedModel(id: info.id, name: info.name))
                            } label: {
                                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(added ? Color.green : Color.accentColor)
                            .disabled(added)
                        }
                    }
                }
                .listStyle(.bordered)
            }
        }
        .task { await load() }
    }

    private var results: [OpenRouterClient.ModelInfo] {
        let terms = search.lowercased().split(separator: " ")
        let filtered = terms.isEmpty ? catalog : catalog.filter { info in
            let haystack = (info.name + " " + info.id).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        return Array(filtered.prefix(200))
    }

    private func load() async {
        do {
            catalog = try await OpenRouterClient.models().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            loadError = "Couldn't load models: \(error.localizedDescription)"
        }
    }
}

/// "$0.10 · $0.20" per million input / output tokens.
struct PriceText: View {
    let info: OpenRouterClient.ModelInfo

    var body: some View {
        Text("\(price(info.inputPrice)) · \(price(info.outputPrice))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("Per million tokens, input · output")
    }

    private func price(_ value: Double?) -> String {
        guard let value else { return "–" }
        if value == 0 { return "Free" }
        return value < 1 ? String(format: "$%.2f", value) : String(format: "$%.1f", value)
    }
}
