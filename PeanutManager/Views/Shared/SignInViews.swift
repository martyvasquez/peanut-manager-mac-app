import SwiftUI

/// Takes the place of an AI action while signed out: starts Sign in with ChatGPT right here.
struct SignInButton: View {
    var prominent = false
    @State private var ai = AIService.shared

    var body: some View {
        VStack(alignment: prominent ? .center : .leading, spacing: 8) {
            if ai.isSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                    Button("Cancel") { ai.cancelSignIn() }.buttonStyle(.link)
                }
            } else if prominent {
                Button { ai.signIn() } label: {
                    Label("Sign In with ChatGPT", systemImage: "sparkles")
                        .font(.title3.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            } else {
                Button("Sign In with ChatGPT", systemImage: "sparkles") { ai.signIn() }
            }
            if let error = ai.signInError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

/// The quiet way into AI where a page could use it: opens Settings (ChatGPT or a Claude key). Never the main action.
struct SetUpAILink: View {
    /// What AI adds here: "for scouting reports".
    var purpose: String

    var body: some View {
        HStack(spacing: 6) {
            SettingsLink { Label("Set Up AI", systemImage: "sparkles") }
                .buttonStyle(.link)
            Text(purpose).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// After the first team is made: AI is optional; connect ChatGPT or a Claude key, or skip it.
struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ai = AIService.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Add AI if You Like").font(.title2.weight(.semibold))
            Text("Peanut Manager works on its own. With your ChatGPT plan or a Claude API key, AI can also suggest lineups and scout your players.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if ai.isSigningIn {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                        Button("Cancel") { ai.cancelSignIn() }.buttonStyle(.link)
                    }
                } else {
                    ContinueWithChatGPTButton { ai.signIn() }
                }
            }
            .frame(height: 36)
            .padding(.top, 4)
            if let error = ai.signInError {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            SettingsLink { Text("Use a Claude API Key") }
                .buttonStyle(.link)
                .simultaneousGesture(TapGesture().onEnded { dismiss() })
            Button("Not Now") { dismiss() }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 420)
        .onChange(of: ai.isReady) { _, ready in if ready { dismiss() } }
    }
}
