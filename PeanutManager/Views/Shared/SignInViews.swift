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

/// What season stats or AI would add right here, for a coach who hasn't brought them in yet. The same card
/// everywhere, sitting where the feature would be, so the coach always knows what they're missing.
struct Unlock: View {
    enum Kind { case ai, stats }

    let kind: Kind
    /// The feature, named like a heading: "Team Summary".
    let title: String
    /// What it gives the coach, in one line.
    let message: String
    /// The team the stats go to; needed for `.stats`.
    var team: Team?
    /// One tight row for small places (a popover, a column), instead of a card.
    var compact = false
    /// Runs instead of the built-in import, for places that can't present a file picker (a popover).
    var onImport: (() -> Void)?

    @State private var importing = false
    @State private var settingUp = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 4) {
                    Label { Text(title).fontWeight(.semibold) } icon: { icon }
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    action.buttonStyle(.link).padding(.top, 2)
                }
                .font(.callout)
            } else {
                HStack(spacing: 14) {
                    icon.font(.title2).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).fontWeight(.semibold)
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    action
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 720, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $settingUp) { SignInSheet(title: title, message: message) }
        .gameChangerImport(team: onImport == nil ? team : nil, isPresented: $importing)
    }

    private var icon: some View {
        Image(systemName: kind == .ai ? "sparkles" : "chart.bar.xaxis").foregroundStyle(.tint)
    }

    private var action: some View {
        Button(kind == .ai ? "Set Up AI…" : "Import Stats…") {
            switch kind {
            case .ai: settingUp = true
            case .stats: if let onImport { onImport() } else { importing = true }
            }
        }
        .help(kind == .ai ? "Use your ChatGPT plan or a Claude API key" : "A GameChanger season stats export (CSV)")
    }
}

/// Opens AI setup for one feature, from a button that stands where the AI action would be.
struct AIFeatureButton: View {
    let title: String
    let feature: String
    let message: String
    @State private var settingUp = false

    var body: some View {
        Button { settingUp = true } label: {
            Label(title, systemImage: "sparkles").padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Set up AI to do this for you")
        .sheet(isPresented: $settingUp) { SignInSheet(title: feature, message: message) }
    }
}

/// After the first team is made, or from a feature that needs AI: connect ChatGPT or a Claude key, or skip it.
struct SignInSheet: View {
    var title = "Add AI if You Like"
    var message = "Peanut Manager works on its own. With your ChatGPT plan or a Claude API key, AI can also suggest lineups and scout your players."
    @Environment(\.dismiss) private var dismiss
    @State private var ai = AIService.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
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
