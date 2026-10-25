import SwiftUI
import LineupAI

/// The AI: the coach's ChatGPT plan or their own Claude key. One at a time: the connected one, with a quiet way
/// to switch; both only while neither is set up. The Mac's wording.
struct SettingsScreen: View {
    /// Opened from a feature that needs AI: what it does, above the setup.
    var feature: AIFeature?
    @Bindable private var ai = AIService.shared
    @Environment(\.dismiss) private var dismiss
    /// The coach asked to switch to the other service; its setup shows until it's connected.
    @State private var switching = false

    var body: some View {
        NavigationStack {
            Form {
                if let feature, !ai.isReady {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(feature.title, systemImage: "sparkles").font(.headline)
                            Text(feature.message).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if ai.isSignedIn {
                    ChatGPTSettings()
                    if switching {
                        ClaudeSettings(replacing: "ChatGPT")
                    } else {
                        Section { Button("Use Claude Instead") { switching = true } }
                    }
                } else if ai.hasClaudeKey {
                    ClaudeSettings()
                    if switching {
                        ChatGPTSettings(replacing: "your Claude key")
                    } else {
                        Section { Button("Use ChatGPT Instead") { switching = true } }
                    }
                } else {
                    ChatGPTSettings()
                    ClaudeSettings()
                }
            }
            .onChange(of: ai.isSignedIn) { switching = false }
            .onChange(of: ai.hasClaudeKey) { switching = false }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("You're using your ChatGPT plan", isPresented: $ai.showWelcome) {
                Button("Got It") {}
                Link("Manage Usage", destination: ChatGPTAuth.manageUsageURL)
            } message: {
                Text("Lineups and scouting reports in Peanut Manager use your ChatGPT plan. You can review and limit usage in ChatGPT settings.")
            }
        }
    }
}

/// Sign in with ChatGPT, the account, and the model it runs.
struct ChatGPTSettings: View {
    /// What signing in replaces, when switching from Claude: "your Claude key".
    var replacing: String?
    private var ai: AIService { .shared }

    var body: some View {
        if ai.isSignedIn {
            Section {
                LabeledContent("Account", value: ai.account?.email ?? ai.account?.name ?? "ChatGPT")
                LabeledContent("Model", value: ai.currentModelName)
                if ai.planUsageGranted {
                    LabeledContent("Billing", value: "Your ChatGPT plan")
                } else {
                    LabeledContent("Billing") {
                        Button("Turn On Plan Use") { ai.signIn(askConsent: true) }
                    }
                }
                Link("Manage Usage", destination: ChatGPTAuth.manageUsageURL)
                Button("Sign Out", role: .destructive) { ai.signOut() }
            } header: {
                Text("ChatGPT")
            } footer: {
                if let error = ai.signInError { Text(error) }
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
                            ProgressView()
                            Text("Signing in…").foregroundStyle(.secondary)
                            Button("Cancel") { ai.cancelSignIn() }
                        }
                        .frame(height: 44)
                    } else {
                        ContinueWithChatGPTButton { ai.signIn() }
                    }
                    if let error = ai.signInError {
                        Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    if ai.account != nil && !ai.isSigningIn {
                        Button("Use a Different Account") { ai.useDifferentAccount() }
                            .font(.callout)
                    }
                    if let replacing {
                        Text("Signing in removes \(replacing).").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }
}

/// The coach's own Anthropic API key, for running on Claude.
struct ClaudeSettings: View {
    /// What a checked key replaces, when switching from ChatGPT: "ChatGPT".
    var replacing: String?
    private var ai: AIService { .shared }
    @State private var draft = ""

    var body: some View {
        Section {
            if let masked = ai.maskedClaudeKey {
                LabeledContent("API Key", value: masked)
                LabeledContent("Model", value: ai.currentModelName)
                LabeledContent("Billing", value: "Your Anthropic account")
                Button("Remove Key", role: .destructive) { ai.removeClaudeKey() }
            } else {
                HStack {
                    SecureField("API Key", text: $draft, prompt: Text("Paste your key"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                    if ai.isCheckingKey {
                        ProgressView()
                    } else {
                        Button("Add", action: save)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        } header: {
            Text("Claude")
        } footer: {
            if let error = ai.keyError {
                Text(error).foregroundStyle(.red)
            } else if let replacing {
                Text("Adding a key signs out of \(replacing). [Get a Key](\(AnthropicClient.keysURL.absoluteString))")
            } else if !ai.hasClaudeKey {
                Text("Claude Max and Team plans include monthly API credits. [Get a Key](\(AnthropicClient.keysURL.absoluteString))")
            }
        }
    }

    private func save() {
        Task { if await ai.saveClaudeKey(draft) { draft = "" } }
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
                .padding(.horizontal, 24)
                .frame(height: 44)
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// An AI action shown to a coach who hasn't set up AI: what it would do, and the way to turn it on.
/// The Mac's wording.
enum AIFeature: String, Identifiable {
    case battingOrder, positions

    var id: Self { self }

    var title: String {
        switch self {
        case .battingOrder: "Let AI Make the Batting Order"
        case .positions: "Let AI Fill the Positions"
        }
    }

    var message: String {
        switch self {
        case .battingOrder: "AI weighs season stats, your ratings and notes, and the matchup, then explains every spot."
        case .positions: "Set the spots you care about. AI fills the rest so every rule is met and every kid gets fair time."
        }
    }
}
