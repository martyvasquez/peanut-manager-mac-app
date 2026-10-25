import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LineupKit

/// Picks a GameChanger season export (CSV) from Files, then the match review: rows can update a player, become a
/// new one, or be skipped, so the same import fills an empty roster or refreshes stats. The Mac's flow.
struct GameChangerImporter: ViewModifier {
    let team: Team
    @Binding var isPresented: Bool
    @State private var pending: PendingImport?
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                switch result {
                case .success(let url): load(url)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .sheet(item: $pending) { ImportSheet(team: team, pending: $0) }
            #if DEBUG
            // `-PMImportSample YES` reviews the bundled sample export, as if picked in Files.
            .onAppear {
                if UserDefaults.standard.bool(forKey: "PMImportSample"), pending == nil,
                   let url = Bundle.main.url(forResource: "sample-team", withExtension: "csv") { load(url) }
            }
            #endif
            .alert("Couldn't Import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let rows = try GameChangerImport.parse(String(contentsOf: url, encoding: .utf8))
            pending = PendingImport(fileName: url.lastPathComponent, rows: rows)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension View {
    func gameChangerImport(team: Team, isPresented: Binding<Bool>) -> some View {
        modifier(GameChangerImporter(team: team, isPresented: isPresented))
    }

    /// No import without a team.
    @ViewBuilder
    func gameChangerImport(team: Team?, isPresented: Binding<Bool>) -> some View {
        if let team { gameChangerImport(team: team, isPresented: isPresented) } else { self }
    }
}

struct PendingImport: Identifiable {
    let id = UUID()
    let fileName: String
    let rows: [GameChangerRow]
}

/// Review matches before anything is saved. Jersey number, then exact name; anything unsure is left to the coach.
struct ImportSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let team: Team
    let pending: PendingImport
    @State private var choices: [Int: Choice] = [:]

    enum Choice: Hashable {
        case player(UUID)
        case newPlayer
        case skip
    }

    var body: some View {
        let picked = choices.values
        let updates = picked.filter { if case .player = $0 { true } else { false } }.count
        let added = picked.filter { $0 == .newPlayer }.count
        NavigationStack {
            List {
                Section {
                    ForEach(Array(pending.rows.enumerated()), id: \.offset) { index, row in
                        Picker(selection: Binding(get: { choices[index] ?? .skip }, set: { choices[index] = $0 })) {
                            ForEach(team.activePlayers) { Text($0.name).tag(Choice.player($0.uid)) }
                            Divider()
                            Text("New Player").tag(Choice.newPlayer)
                            Text("Skip").tag(Choice.skip)
                        } label: {
                            HStack(spacing: 10) {
                                Text(row.number).monospacedDigit().foregroundStyle(.tertiary).frame(minWidth: 24, alignment: .trailing)
                                Text(row.fullName)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text(pending.fileName)
                } footer: {
                    Text(summary(updates: updates, added: added))
                }
            }
            .navigationTitle("Import Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { apply(); dismiss() }
                        .disabled(updates + added == 0)
                }
            }
        }
        .onAppear(perform: match)
    }

    private func summary(updates: Int, added: Int) -> String {
        var parts: [String] = []
        if updates > 0 { parts.append("Updates \(updates) player\(updates == 1 ? "" : "s")") }
        if added > 0 { parts.append("adds \(added) new") }
        let skipped = pending.rows.count - updates - added
        if skipped > 0 { parts.append("skips \(skipped)") }
        return parts.isEmpty ? "" : parts.joined(separator: ", ").capitalizedFirst + "."
    }

    private func match() {
        let roster = team.activePlayers.map(\.snapshot)
        for (index, row) in pending.rows.enumerated() {
            switch GameChangerImport.match(row, roster: roster) {
            case .jersey(let id), .name(let id): choices[index] = .player(id)
            case .none: choices[index] = team.players.isEmpty ? .newPlayer : .skip
            case .ambiguous: choices[index] = .skip
            }
        }
    }

    private func apply() {
        var nextIndex = (team.players.map(\.sortIndex).max() ?? -1) + 1
        for (index, row) in pending.rows.enumerated() {
            let stats = PlayerStats(batting: row.batting, fielding: row.fielding, pitching: row.pitching)
            switch choices[index] ?? .skip {
            case .player(let uid):
                if let player = team.players.first(where: { $0.uid == uid }) {
                    player.stats = stats
                    player.applyGameChangerHistory()
                }
            case .newPlayer:
                let player = Player(name: row.fullName, jersey: row.number, sortIndex: nextIndex)
                nextIndex += 1
                context.insert(player)
                player.team = team
                player.stats = stats
                player.applyGameChangerHistory()
            case .skip:
                break
            }
        }
        team.statsImportedAt = .now
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
