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

/// After the first team is made: one step to connect ChatGPT, or skip it for now.
struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ai = AIService.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Make Lineups with ChatGPT").font(.title2.weight(.semibold))
            Text("Peanut Manager runs on your ChatGPT Plus or Pro plan. No API key needed.")
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
            Button("Later") { dismiss() }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 420)
        .onChange(of: ai.isSignedIn) { _, signedIn in if signedIn { dismiss() } }
    }
}
