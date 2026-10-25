import SwiftUI
import LineupKit

/// Season numbers as tiles, one labeled row per kind. Ranked stats show where the player stands on the team.
struct StatTiles: View {
    let stats: PlayerStats
    let player: PlayerID
    let ranks: TeamRanks
    var kinds: Set<Metric.Kind> = [.hitting, .fielding, .pitching]

    private enum Tile {
        case ranked(Metric)
        case plain(String, String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if kinds.contains(.hitting), let b = stats.batting, b.pa > 0 {
                row("Hitting", [.ranked(.avg), .ranked(.obp), .ranked(.slg), .ranked(.kRate), .ranked(.bbRate), .ranked(.sb), .plain("\(b.pa)", "PA")])
            }
            if kinds.contains(.fielding), let f = stats.fielding, f.tc > 0 || f.catcherOuts > 0 {
                row("Fielding", (f.tc > 0 ? [.ranked(.fpct), .plain("\(f.e)", "E")] : [])
                    + (f.catcherOuts > 0 ? [.plain("\(f.catcherOuts / 3).\(f.catcherOuts % 3)", "INN CAUGHT")] : []))
            }
            if kinds.contains(.pitching), let p = stats.pitching, p.outs > 0 {
                row("Pitching", [.plain(p.ipText, "IP"), .ranked(.era), .ranked(.whip), .ranked(.pitchKRate), .plain("\(p.bb)", "BB")])
            }
        }
    }

    private func row(_ title: String, _ tiles: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // A single kind sits under its own section heading already.
            if kinds.count > 1 { Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            TileRow(alignment: .top, spacing: 10) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    self.tile(tile)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ tile: Tile) -> some View {
        let standing: Standing? = if case .ranked(let metric) = tile { ranks.standing(player, metric) } else { nil }
        let (value, label): (String, String) = switch tile {
        case .ranked(let metric): (standing.map { metric.format($0.value) } ?? "–", metric.label)
        case .plain(let value, let label): (value, label)
        }
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(standing != nil && standing?.rank == nil ? .secondary : .primary)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            VStack(spacing: 5) {
                if let standing {
                    if standing.rank != nil { StandingStrip(standing: standing, ranks: ranks) }
                    RankLabel(standing: standing).font(.caption2.weight(.medium))
                }
            }
            .frame(height: 30, alignment: .bottom)
        }
        .frame(width: 84)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .help(standing.map(help) ?? "")
    }

    private func help(_ standing: Standing) -> String {
        guard let rank = standing.rankText else { return "Too few chances to rank against the team yet" }
        return "\(rank) of \(standing.of) qualified players on the team"
    }
}
