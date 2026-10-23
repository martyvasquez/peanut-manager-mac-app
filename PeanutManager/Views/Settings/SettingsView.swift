import SwiftUI
import LineupAI

struct SettingsView: View {
    @State private var ai = AIService.shared

    /// The coach asked to switch to the other service; its setup shows until it's connected.
    @State private var switching = false

    var body: some View {
        // One AI at a time: the connected one, with a quiet way to switch; both only while neither is set up.
        Form {
            if ai.isSignedIn {
                ChatGPTSettings()
                if switching {
                    ClaudeSettings(replacing: "ChatGPT")
                } else {
                    Section { Button("Use Claude Instead") { switching = true }.buttonStyle(.link) }
                }
            } else if ai.hasClaudeKey {
                ClaudeSettings()
                if switching {
                    ChatGPTSettings(replacing: "your Claude key")
                } else {
                    Section { Button("Use ChatGPT Instead") { switching = true }.buttonStyle(.link) }
                }
            } else {
                ChatGPTSettings()
                ClaudeSettings()
            }
        }
        .onChange(of: ai.isSignedIn) { switching = false }
        .onChange(of: ai.hasClaudeKey) { switching = false }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
            .alert("You're using your ChatGPT plan", isPresented: $ai.showWelcome) {
                Button("Got It") {}
                Link("Manage Usage", destination: ChatGPTAuth.manageUsageURL)
            } message: {
                Text("Lineups and scouting reports in Peanut Manager use your ChatGPT plan. You can review and limit usage in ChatGPT settings.")
            }
    }
}

/// Sign in with ChatGPT, the account, and the model it runs.
struct ChatGPTSettings: View {
    /// What signing in replaces, when switching from Claude: "your Claude key".
    var replacing: String?
    @State private var ai = AIService.shared

    var body: some View {
        if ai.isSignedIn {
            Section {
                LabeledContent("Account", value: ai.account?.email ?? ai.account?.name ?? "ChatGPT")
                LabeledContent("Model", value: ai.currentModelName)
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
            } header: {
                Text("ChatGPT")
            }
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
                    if let replacing {
                        Text("Signing in removes \(replacing).").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
    }
}

/// The coach's own Anthropic API key, for running on Claude.
struct ClaudeSettings: View {
    /// What a checked key replaces, when switching from ChatGPT: "ChatGPT".
    var replacing: String?
    @State private var ai = AIService.shared
    @State private var draft = ""

    var body: some View {
        Section {
            if let masked = ai.maskedClaudeKey {
                LabeledContent("API Key") {
                    HStack {
                        Text(masked).foregroundStyle(.secondary)
                        Button("Remove") { ai.removeClaudeKey() }
                    }
                }
                LabeledContent("Model", value: ai.currentModelName)
                LabeledContent("Billing", value: "Your Anthropic account")
            } else {
                HStack {
                    SecureField("API Key", text: $draft, prompt: Text("Paste your key"))
                        .onSubmit(save)
                    if ai.isCheckingKey {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        } header: {
            Text("Claude")
        } footer: {
            if let error = ai.keyError {
                Text(error).foregroundStyle(.red)
            } else if let replacing {
                HStack(spacing: 4) {
                    Text("Adding a key signs out of \(replacing).").foregroundStyle(.secondary)
                    Link("Get a Key", destination: AnthropicClient.keysURL)
                }
            } else if !ai.hasClaudeKey {
                HStack(spacing: 4) {
                    Text("Claude Max and Team plans include monthly API credits.").foregroundStyle(.secondary)
                    Link("Get a Key", destination: AnthropicClient.keysURL)
                }
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
                .padding(.horizontal, 22)
                .frame(height: 36)
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
