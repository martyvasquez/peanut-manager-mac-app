import SwiftUI
import LineupAI

struct SettingsView: View {
    @State private var ai = AIService.shared

    var body: some View {
        Form { ChatGPTSettings() }
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
                Picker("Model", selection: $ai.chosenModelID) {
                    Text("Default (\(ai.displayName(for: ai.defaultModelID)))").tag(String?.none)
                    Divider()
                    if ai.chatGPTModels.isEmpty, let chosen = ai.chosenModelID { Text(ai.displayName(for: chosen)).tag(Optional(chosen)) }
                    ForEach(ai.chatGPTModels) { Text($0.name).tag(Optional($0.id)) }
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
