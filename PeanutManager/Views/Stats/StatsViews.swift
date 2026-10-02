import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LineupKit

/// One row of the stats table. Missing values sort last (as -1).
nonisolated struct StatRow: Identifiable, Sendable {
    let id: UUID
    let jersey: String
    let name: String
    let pa: Int
    let avg, obp, slg, kRate, bbRate: Double
    let sb: Int
    let fpct: Double
    let errors: Int
    let ip, era: Double
    let ipText: String

    @MainActor init(_ player: Player) {
        let s = player.stats
        let b = s?.batting, f = s?.fielding, p = s?.pitching
        id = player.uid
        jersey = player.jersey
        name = player.name
        pa = b?.pa ?? 0
        avg = b?.avg ?? -1
        obp = b?.obp ?? -1
        slg = b?.slg ?? -1
        kRate = b?.kRate ?? -1
        bbRate = b?.bbRate ?? -1
        sb = b?.sb ?? 0
        fpct = f?.fpct ?? -1
        errors = f?.e ?? 0
        ip = (p?.outs ?? 0) > 0 ? p!.innings : -1
        era = p?.era ?? -1
        ipText = (p?.outs ?? 0) > 0 ? p!.ipText : "–"
    }
}

/// Full-width season stats. Import lives in the toolbar; drop a CSV anywhere on the page.
struct StatsView: View {
    let team: Team
    @State private var sortOrder = [KeyPathComparator(\StatRow.obp, order: .reverse)]
    @State private var importing = false
    @State private var pending: PendingImport?
    @State private var error: String?

    var body: some View {
        let rows = team.activePlayers.filter { $0.stats != nil }.map(StatRow.init).sorted(using: sortOrder)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stats").font(.largeTitle.weight(.bold))
                if let imported = team.statsImportedAt {
                    Text("GameChanger · imported \(imported.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 16)

            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Stats", systemImage: "chart.bar.xaxis")
                } actions: {
                    Button("Import GameChanger Stats…") { importing = true }
                }
            } else {
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Player", value: \.name) { (row: StatRow) in
                        HStack(spacing: 8) {
                            Text(row.jersey).foregroundStyle(.tertiary).monospacedDigit().frame(width: 24, alignment: .trailing)
                            Text(row.name)
                        }
                    }
                    .width(min: 160, ideal: 200)
                    Group {
                        count("PA", \.pa, width: 44)
                        rate("AVG", \.avg)
                        rate("OBP", \.obp)
                        rate("SLG", \.slg)
                        percent("K%", \.kRate)
                        percent("BB%", \.bbRate)
                    }
                    Group {
                        count("SB", \.sb, width: 36)
                        rate("FPCT", \.fpct)
                        count("E", \.errors, width: 32)
                        TableColumn("IP", value: \.ip) { (row: StatRow) in Num(row.ipText) }.width(44)
                        decimal("ERA", \.era, digits: 2, width: 52)
                    }
                }
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar(removing: .title)
        .toolbar {
            Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                .help("Import a GameChanger season export (CSV)")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result { load(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        }
        .sheet(item: $pending) { pending in
            ImportSheet(team: team, pending: pending)
        }
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

    // Typed column helpers keep the Table simple enough for the compiler.

    private func count(_ title: String, _ key: KeyPath<StatRow, Int> & Sendable, width: CGFloat) -> some TableColumnContent<StatRow, KeyPathComparator<StatRow>> {
        TableColumn(title, value: key) { (row: StatRow) in Num("\(row[keyPath: key])") }.width(width)
    }

    private func rate(_ title: String, _ key: KeyPath<StatRow, Double> & Sendable) -> some TableColumnContent<StatRow, KeyPathComparator<StatRow>> {
        TableColumn(title, value: key) { (row: StatRow) in
            let v = row[keyPath: key]
            return Num(v < 0 ? "–" : Fmt.rate(v))
        }
        .width(52)
    }

    private func percent(_ title: String, _ key: KeyPath<StatRow, Double> & Sendable) -> some TableColumnContent<StatRow, KeyPathComparator<StatRow>> {
        TableColumn(title, value: key) { (row: StatRow) in
            let v = row[keyPath: key]
            return Num(v < 0 ? "–" : Fmt.pct(v))
        }
        .width(48)
    }

    private func decimal(_ title: String, _ key: KeyPath<StatRow, Double> & Sendable, digits: Int, width: CGFloat) -> some TableColumnContent<StatRow, KeyPathComparator<StatRow>> {
        TableColumn(title, value: key) { (row: StatRow) in
            let v = row[keyPath: key]
            return Num(v < 0 ? "–" : String(format: "%.\(digits)f", v))
        }
        .width(width)
    }
}

struct Num: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Stats").font(.title2.weight(.semibold))
                Text(pending.fileName).foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(pending.rows.enumerated()), id: \.offset) { index, row in
                    HStack {
                        Text(row.number).monospacedDigit().foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
                        Text(row.fullName)
                        Spacer()
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Picker("Match", selection: Binding(get: { choices[index] ?? .skip }, set: { choices[index] = $0 })) {
                            ForEach(team.activePlayers) { Text($0.name).tag(Choice.player($0.uid)) }
                            Divider()
                            Text("New Player").tag(Choice.newPlayer)
                            Text("Skip").tag(Choice.skip)
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                }
            }
            .frame(minHeight: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: match)
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
