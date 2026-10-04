import SwiftUI
import LineupKit

/// One player's line in the Players table: offense columns, then defense, then how sure the Scout is.
nonisolated struct PlayerInsightRow: Identifiable, Sendable {
    let id: PlayerID
    let jersey: String
    let name: String
    /// Top 0, middle 1, bottom 2, none 3 (sorts last).
    let zoneOrder: Int
    let zone: String
    let role: String
    let obp: Double
    let obpText: String
    let obpTop3: Bool
    let slg: Double
    let slgText: String
    let slgTop3: Bool
    let plays: String
    let confidenceOrder: Int
    let confidence: String
    let status: String
    let failed: Bool

    @MainActor init(_ player: Player, ranks: TeamRanks, runner: ScoutRunner) {
        let a = player.assessment
        id = player.uid
        jersey = player.jersey
        name = player.name
        let z = a?.battingZone
        zoneOrder = z.map { BattingZone.allCases.firstIndex(of: $0)! } ?? 3
        zone = z?.rawValue.capitalized ?? "–"
        role = a.map { $0.battingRole.prefix(1).uppercased() + $0.battingRole.dropFirst() } ?? ""

        let o = ranks.standing(player.uid, .obp), s = ranks.standing(player.uid, .slg)
        obp = o?.value ?? -1
        obpText = o.map { Metric.obp.format($0.value) } ?? "–"
        obpTop3 = (o?.rank ?? 99) <= 3
        slg = s?.value ?? -1
        slgText = s.map { Metric.slg.format($0.value) } ?? "–"
        slgTop3 = (s?.rank ?? 99) <= 3

        // The Scout's strong and solid spots; the coach's best spots when there's no report yet.
        let scout = (a?.defense ?? []).filter { $0.fit <= .solid }.sorted { ($0.fit, $0.position) < ($1.fit, $1.position) }.map(\.position)
        let best = player.profile.strengths.filter { player.profile[$0] >= .good }
        plays = (scout.isEmpty ? best : scout).map(\.label).joined(separator: " · ")

        confidenceOrder = switch a?.confidence { case .high: 0; case .medium: 1; case .low: 2; case nil: 3 }
        confidence = a?.confidence.rawValue.capitalized ?? ""

        switch runner.jobs[player.uid] {
        case .failed(let message)?:
            status = message; failed = true
        case let job? where job.isActive:
            status = "Assessing…"; failed = false
        default:
            failed = false
            status = a == nil ? (player.isAssessable ? "Not assessed" : "No data") : runner.isStale(player) ? "Changed" : ""
        }
    }
}

/// Every player at a glance, sortable. Double-click opens the scouting report.
struct PlayersTable: View {
    let team: Team
    @State private var runner = ScoutRunner.shared
    @State private var sortOrder = [KeyPathComparator(\PlayerInsightRow.zoneOrder), KeyPathComparator(\PlayerInsightRow.obp, order: .reverse)]
    @State private var selection: PlayerID?

    var body: some View {
        let ranks = team.ranks
        let rows = team.activePlayers.map { PlayerInsightRow($0, ranks: ranks, runner: runner) }.sorted(using: sortOrder)

        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Player", value: \.name) { (row: PlayerInsightRow) in
                HStack(spacing: 8) {
                    Text(row.jersey).foregroundStyle(.tertiary).monospacedDigit().frame(width: 24, alignment: .trailing)
                    Text(row.name)
                }
            }
            .width(min: 150, ideal: 180)
            TableColumn("Bats", value: \.zoneOrder) { (row: PlayerInsightRow) in
                Text(row.zone).foregroundStyle(row.zoneOrder == 3 ? .tertiary : .primary)
            }
            .width(64)
            TableColumn("Hitter", value: \.role) { (row: PlayerInsightRow) in
                Text(row.role).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            TableColumn("OBP", value: \.obp) { (row: PlayerInsightRow) in
                Num(row.obpText).foregroundStyle(row.obpTop3 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .width(48)
            TableColumn("SLG", value: \.slg) { (row: PlayerInsightRow) in
                Num(row.slgText).foregroundStyle(row.slgTop3 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .width(48)
            TableColumn("Plays", value: \.plays) { (row: PlayerInsightRow) in
                Text(row.plays).padding(.leading, 16)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Confidence", value: \.confidenceOrder) { (row: PlayerInsightRow) in
                Text(row.confidence).foregroundStyle(.secondary)
            }
            .width(80)
            TableColumn("", value: \.status) { (row: PlayerInsightRow) in
                Text(row.status).foregroundStyle(row.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary)).lineLimit(1)
                    .help(row.status)
            }
            .width(min: 80, ideal: 110)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 24)
        .contextMenu(forSelectionType: PlayerID.self) { ids in
            if let player = player(ids.first) {
                Button("Open Scouting Report") { Navigator.shared.openScoutingReport(player) }
                Button("Open Stats") { Navigator.shared.open(player, tab: .stats) }
            }
        } primaryAction: { ids in
            if let player = player(ids.first) { Navigator.shared.openScoutingReport(player) }
        }
    }

    private func player(_ id: PlayerID?) -> Player? {
        team.players.first { $0.uid == id }
    }
}
