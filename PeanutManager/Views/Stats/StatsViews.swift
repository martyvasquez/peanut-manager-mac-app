import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LineupKit

struct StatsListView: View {
    let team: Team

    var body: some View {
        let players = team.activePlayers
        Table(players) {
            TableColumn("Player") { p in Text(p.name) }
                .width(min: 120, ideal: 150)
            TableColumn("PA") { p in Text(p.stats?.batting.map { "\($0.pa)" } ?? "–").monospacedDigit() }
                .width(36)
            TableColumn("AVG/OBP/SLG") { p in
                Text(p.stats?.batting.map { "\(Fmt.rate($0.avg)) / \(Fmt.rate($0.obp)) / \(Fmt.rate($0.slg))" } ?? "–").monospacedDigit()
            }
            .width(min: 110, ideal: 130)
            TableColumn("FPCT") { p in Text(Fmt.rate(p.stats?.fielding?.fpct)).monospacedDigit() }
                .width(46)
            TableColumn("IP") { p in Text(p.stats?.pitching.flatMap { $0.outs > 0 ? String(format: "%.1f", $0.innings) : nil } ?? "–").monospacedDigit() }
                .width(36)
        }
        .navigationTitle("Stats")
        .navigationSplitViewColumnWidth(min: 380, ideal: 440)
        .overlay {
            if players.allSatisfy({ $0.stats == nil }) {
                ContentUnavailableView("No Stats", systemImage: "chart.bar.xaxis")
            }
        }
    }
}

/// Import a GameChanger CSV: preview every match before anything is saved. No fuzzy guessing.
struct ImportStatsView: View {
    @Environment(\.modelContext) private var context
    let team: Team
    @State private var rows: [GameChangerRow] = []
    @State private var choices: [Int: Choice] = [:]
    @State private var fileName = ""
    @State private var error: String?
    @State private var importing = false
    @State private var done: String?

    enum Choice: Hashable {
        case player(UUID)
        case newPlayer
        case skip
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Stats").font(.largeTitle.weight(.bold))
            Text("Drop a GameChanger season export here.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose File…") { importing = true }
                if !fileName.isEmpty { Text(fileName).foregroundStyle(.secondary) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let done { Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }

            if !rows.isEmpty {
                List {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack {
                            Text("#\(row.number)").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                            Text(row.fullName).frame(width: 160, alignment: .leading)
                            Picker("Match", selection: Binding(get: { choices[index] ?? .skip }, set: { choices[index] = $0 })) {
                                ForEach(team.activePlayers) { Text($0.name).tag(Choice.player($0.uid)) }
                                Divider()
                                Text("New Player").tag(Choice.newPlayer)
                                Text("Skip").tag(Choice.skip)
                            }
                            .labelsHidden()
                        }
                    }
                }
                .frame(minHeight: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { rows = []; fileName = "" }
                    Button("Import") { apply() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result { load(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        }
    }

    private func load(_ url: URL) {
        error = nil
        done = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            rows = try GameChangerImport.parse(text)
            fileName = url.lastPathComponent
            let roster = team.activePlayers.map(\.snapshot)
            choices = [:]
            for (index, row) in rows.enumerated() {
                switch GameChangerImport.match(row, roster: roster) {
                case .jersey(let id), .name(let id): choices[index] = .player(id)
                case .none: choices[index] = team.players.isEmpty ? .newPlayer : .skip
                case .ambiguous: choices[index] = .skip
                }
            }
        } catch {
            self.error = error.localizedDescription
            rows = []
        }
    }

    private func apply() {
        var count = 0
        var nextIndex = (team.players.map(\.sortIndex).max() ?? -1) + 1
        for (index, row) in rows.enumerated() {
            let stats = PlayerStats(batting: row.batting, fielding: row.fielding, pitching: row.pitching)
            switch choices[index] ?? .skip {
            case .player(let uid):
                if let player = team.players.first(where: { $0.uid == uid }) {
                    player.stats = stats
                    player.applyGameChangerHistory()
                }
                count += 1
            case .newPlayer:
                let player = Player(name: row.fullName, jersey: row.number, sortIndex: nextIndex)
                nextIndex += 1
                context.insert(player)
                player.team = team
                player.stats = stats
                player.applyGameChangerHistory()
                count += 1
            case .skip:
                break
            }
        }
        team.statsImportedAt = .now
        done = "\(count) players updated"
        rows = []
    }
}
