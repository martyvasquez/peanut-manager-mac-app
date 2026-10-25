import SwiftUI
import SwiftData
import LineupKit

/// The season stats on a phone: one row per kid with the numbers for the chosen sort, best first. The Mac's
/// `StatsView` is a wide table; this is its narrow form, with the same import.
struct StatsView: View {
    let team: Team
    @State private var sort: Metric = .obp
    @State private var importing = false

    private static let sorts: [Metric] = [.avg, .obp, .slg, .fpct, .era]

    var body: some View {
        let ranks = TeamRanks(team.activePlayers.map { ($0.uid, $0.stats) })
        let players = team.activePlayers.filter { $0.stats != nil }
        let sorted = players.sorted { a, b in
            let x = ranks.standing(a.uid, sort), y = ranks.standing(b.uid, sort)
            switch (x?.rank, y?.rank) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.sortIndex < b.sortIndex
            }
        }
        List {
            if players.isEmpty {
                Unlock(kind: .stats, title: "Season Stats", message: "Import your GameChanger season stats to see every kid's numbers and where they rank.", team: team)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(sorted) { player in
                        row(player, ranks)
                    }
                } header: {
                    HStack {
                        Text("Player")
                        Spacer()
                        ForEach(columns, id: \.self) { Text($0.label).frame(width: 52, alignment: .trailing) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort By", selection: $sort) {
                        ForEach(Self.sorts, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import", systemImage: "square.and.arrow.down") { importing = true }
            }
        }
        .gameChangerImport(team: team, isPresented: $importing)
    }

    /// The sorted stat first, then the two that go with it.
    private var columns: [Metric] {
        switch sort {
        case .fpct: [.fpct]
        case .era: [.era, .whip]
        default: [sort] + [Metric.avg, .obp, .slg].filter { $0 != sort }
        }
    }

    private func row(_ player: Player, _ ranks: TeamRanks) -> some View {
        HStack {
            Text(player.jersey).monospacedDigit().foregroundStyle(.tertiary).frame(minWidth: 22, alignment: .trailing)
            Text(player.name).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(columns, id: \.self) { metric in
                let standing = ranks.standing(player.id, metric)
                Text(standing.map { metric.format($0.value) } ?? "–")
                    .monospacedDigit()
                    .fontWeight(metric == sort ? .semibold : .regular)
                    .foregroundStyle(standing?.rank.map { $0 <= 3 && metric == sort } == true ? AnyShapeStyle(Color.accentColor)
                                     : standing == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .font(.subheadline)
    }
}

private extension Player {
    var id: PlayerID { uid }
}
