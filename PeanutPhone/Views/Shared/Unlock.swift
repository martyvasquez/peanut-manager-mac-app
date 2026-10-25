import SwiftUI
import SwiftData

/// What a feature would show, and the one or two steps to get it (import stats, set up AI). The Mac's `Unlock`,
/// with the same interface so the shared Insights views use it as is.
struct Unlock: View {
    enum Kind { case stats, ai }

    /// What's missing, each with its own button (stats first: it's the one to do first).
    let needs: [Kind]
    let title: String
    let message: String
    var team: Team?
    /// One tight block for small places, instead of a card.
    var compact = false
    /// Runs instead of the built-in import.
    var onImport: (() -> Void)?

    @State private var importing = false
    @State private var settingUp = false

    init(kind: Kind, title: String, message: String, team: Team? = nil, compact: Bool = false, onImport: (() -> Void)? = nil) {
        self.init(needs: [kind], title: title, message: message, team: team, compact: compact, onImport: onImport)
    }

    init(needs: [Kind], title: String, message: String, team: Team? = nil, compact: Bool = false, onImport: (() -> Void)? = nil) {
        self.needs = needs.sorted { $0 == .stats && $1 == .ai }
        self.title = title
        self.message = message
        self.team = team
        self.compact = compact
        self.onImport = onImport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Label { Text(title).fontWeight(.semibold) } icon: {
                Image(systemName: needs.contains(.ai) ? "sparkles" : "chart.bar.xaxis").foregroundStyle(.tint)
            }
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(needs, id: \.self) { kind in
                    switch kind {
                    case .stats: Button("Import Stats") { if let onImport { onImport() } else { importing = true } }
                    case .ai: Button("Set Up AI") { settingUp = true }
                    }
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .padding(.top, 2)
        }
        .font(compact ? .callout : .body)
        .padding(compact ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $settingUp) { SettingsScreen(title: title, message: message) }
        .gameChangerImport(team: onImport == nil ? team : nil, isPresented: $importing)
    }
}
