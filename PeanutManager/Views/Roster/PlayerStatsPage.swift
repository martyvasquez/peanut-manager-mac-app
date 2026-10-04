import SwiftUI
import LineupKit

/// A player's season, Offense then Defense: where they rank, how their plate appearances end,
/// where they sit on the team maps, and the stat tiles.
struct PlayerStatsPage: View {
    let player: Player
    let stats: PlayerStats
    let team: Team

    var body: some View {
        let ranks = team.ranks
        VStack(alignment: .leading, spacing: 28) {
            RankBadges(player: player.uid, ranks: ranks)

            if let b = stats.batting, b.pa > 0 {
                PageSection("Offense")
                StatTiles(stats: stats, player: player.uid, ranks: ranks, kinds: [.hitting])
                PlateAppearances(line: b, team: team.activePlayers.compactMap { $0.stats?.batting })
                HStack(alignment: .top, spacing: 16) {
                    HitterMap(team: team, ranks: ranks, highlight: player.uid, height: 220)
                    TwoWayMap(team: team, ranks: ranks, highlight: player.uid, height: 220)
                }
            }

            if hasDefense {
                PageSection("Defense")
                StatTiles(stats: stats, player: player.uid, ranks: ranks, kinds: [.fielding, .pitching])
            }
        }
    }

    private var hasDefense: Bool {
        (stats.fielding.map { $0.tc > 0 || $0.catcherOuts > 0 } ?? false) || (stats.pitching?.outs ?? 0) > 0
    }
}

/// The player's best team ranks (top three, at most four badges): "1st Walks".
struct RankBadges: View {
    let player: PlayerID
    let ranks: TeamRanks

    var body: some View {
        let top = Metric.allCases
            .compactMap { ranks.standing(player, $0) }
            .filter { ($0.rank ?? 99) <= 3 }
            .sorted { ($0.rank!, $0.metric.title) < ($1.rank!, $1.metric.title) }
            .prefix(4)
        if !top.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(Array(top), id: \.metric) { s in
                    HStack(spacing: 5) {
                        Text(s.rankText!).fontWeight(.bold)
                        Text(s.metric.title)
                    }
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .help("\(s.rankText!) of \(s.of) on the team in \(s.metric.label): \(s.metric.format(s.value))")
                }
            }
        }
    }
}

/// How plate appearances end, as one bar: hits (by type), walks, outs in play, strikeouts.
/// The team's split sits underneath, faint, for comparison.
struct PlateAppearances: View {
    let line: BattingLine
    let team: [BattingLine]

    private struct Part: Identifiable {
        let id: String
        let count: Int
        let color: Color
    }

    var body: some View {
        let mine = Self.parts(line)
        var total = BattingLine()
        for b in team {
            total.pa += b.pa; total.h += b.h; total.singles += b.singles; total.doubles += b.doubles
            total.triples += b.triples; total.hr += b.hr; total.bb += b.bb; total.hbp += b.hbp; total.so += b.so
        }
        return VStack(alignment: .leading, spacing: 10) {
            Caption("How Plate Appearances End")
            bar(mine, height: 22)
            bar(Self.parts(total), height: 6).opacity(0.6)
                .help("Team")
            HStack(spacing: 16) {
                ForEach(mine.filter { $0.count > 0 }) { part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 10, height: 10)
                        Text(part.id).foregroundStyle(.secondary)
                        Text("\(part.count)").monospacedDigit()
                    }
                }
                Spacer()
                Text("Team below").foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
    }

    private func bar(_ parts: [Part], height: CGFloat) -> some View {
        let sum = max(parts.reduce(0) { $0 + $1.count }, 1)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(parts.filter { $0.count > 0 }) { part in
                    Rectangle().fill(part.color)
                        .frame(width: max(0, (geo.size.width - 2 * CGFloat(parts.count - 1)) * CGFloat(part.count) / CGFloat(sum)))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 3))
    }

    /// Hits in the accent color (one block per kind), then walks, outs in play and strikeouts in grays.
    private static func parts(_ b: BattingLine) -> [Part] {
        let walks = b.bb + b.hbp
        let outsInPlay = max(0, b.pa - b.h - walks - b.so)
        return [
            Part(id: "1B", count: b.singles, color: .accentColor),
            Part(id: "2B", count: b.doubles, color: .accentColor),
            Part(id: "3B", count: b.triples, color: .accentColor),
            Part(id: "HR", count: b.hr, color: .accentColor),
            Part(id: "Walks", count: walks, color: .primary.opacity(0.45)),
            Part(id: "Outs in play", count: outsInPlay, color: .primary.opacity(0.22)),
            Part(id: "Strikeouts", count: b.so, color: .primary.opacity(0.1)),
        ]
    }
}
