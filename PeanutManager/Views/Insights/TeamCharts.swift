import SwiftUI
import Charts
import LineupKit

extension Team {
    /// Team rankings on every stat; decodes each player's stats, so build once per view.
    var ranks: TeamRanks { TeamRanks(activePlayers.map { ($0.uid, $0.stats) }) }
}

/// Every qualified teammate as a faint dot on one line, better to the right; this player is the solid dot.
struct StandingStrip: View {
    let standing: Standing
    let ranks: TeamRanks
    var width: CGFloat = 72

    var body: some View {
        let values = ranks.ranked(standing.metric).map(\.value)
        let lo = values.min() ?? standing.value, hi = values.max() ?? standing.value
        Canvas { context, size in
            func x(_ v: Double) -> CGFloat {
                guard hi > lo else { return size.width / 2 }
                let t = (v - lo) / (hi - lo)
                return 3 + (standing.metric.higherIsBetter ? t : 1 - t) * (size.width - 6)
            }
            let mid = size.height / 2
            context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(.primary.opacity(0.12)))
            for v in values {
                context.fill(Path(ellipseIn: CGRect(x: x(v) - 2.5, y: mid - 2.5, width: 5, height: 5)), with: .color(.primary.opacity(0.28)))
            }
            let me = x(standing.value)
            let color: Color = (standing.rank ?? 99) <= 3 ? .accentColor : .primary
            context.fill(Path(ellipseIn: CGRect(x: me - 4, y: mid - 4, width: 8, height: 8)), with: .color(color))
        }
        .frame(width: width, height: 10)
        .accessibilityHidden(true)
    }
}

/// "2nd of 11" in the accent color for the top three; "Small sample" when the player doesn't qualify.
struct RankLabel: View {
    let standing: Standing

    var body: some View {
        if let text = standing.rankText {
            Text("\(text) of \(standing.of)")
                .foregroundStyle(standing.rank! <= 3 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        } else {
            Text("Small sample").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Team page

/// Team totals from the fact sheet, so they match what the AI was told.
struct TeamNumbers: View {
    let team: Team

    private static let shown = ["team.avg", "team.obp", "team.slg", "team.k_rate", "team.bb_rate", "team.sb", "team.fpct", "team.p.whip"]

    var body: some View {
        let sheet = FactSheet.team(team.activePlayers.map(\.snapshot))
        let facts = Self.shown.compactMap { sheet[$0] }
        if !facts.isEmpty {
            HStack(spacing: 10) {
                ForEach(facts, id: \.id) { fact in
                    VStack(spacing: 2) {
                        Text(fact.value).font(.title3.weight(.semibold).monospacedDigit())
                        Text(Self.short(fact)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 72)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    /// "Team K%" → "K%"; "Team stolen bases" → "SB".
    private static func short(_ fact: Fact) -> String {
        switch fact.id {
        case "team.sb": "SB"
        case "team.fpct": "FPCT"
        case "team.p.whip": "WHIP"
        default: fact.label.replacingOccurrences(of: "Team ", with: "")
        }
    }
}

/// Top three on each stat, ties included. Names open the player's stats.
struct TeamLeaders: View {
    let team: Team
    let ranks: TeamRanks

    private static let metrics: [Metric] = [.obp, .slg, .kRate, .bbRate, .sb, .fpct, .whip, .pitchKRate]

    var body: some View {
        let cards = Self.metrics.filter { !ranks.leaders($0).isEmpty }
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Caption("Team Leaders")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(cards, id: \.self) { card($0) }
                }
            }
        }
    }

    private func card(_ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title).font(.callout.weight(.semibold))
                Spacer()
                Text(metric.label).font(.caption.weight(.medium)).foregroundStyle(.tertiary)
            }
            ForEach(ranks.leaders(metric), id: \.player) { standing in
                if let player = team.players.first(where: { $0.uid == standing.player }) {
                    HStack(spacing: 8) {
                        Text("\(standing.rank!)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, alignment: .trailing)
                        Button(player.name) { Navigator.shared.open(player, tab: .stats) }
                            .buttonStyle(.plain)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(metric.format(standing.value))
                            .font(.callout.monospacedDigit().weight(standing.rank == 1 ? .semibold : .regular))
                    }
                    .help("Open \(player.name)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// On-base % against strikeout rate for every qualified hitter, split at the team's own rates.
/// Up and right is better, so the top-right corner holds the table-setters.
struct HitterMap: View {
    let team: Team
    let ranks: TeamRanks

    private struct Point: Identifiable {
        let id: PlayerID
        let name: String
        let obp: Double
        let k: Double
    }

    var body: some View {
        let points = ranks.ranked(.obp).compactMap { s -> Point? in
            guard let k = ranks.standing(s.player, .kRate)?.value,
                  let player = team.players.first(where: { $0.uid == s.player }) else { return nil }
            return Point(id: s.player, name: player.name.split(separator: " ").first.map(String.init) ?? player.name, obp: s.value, k: k)
        }
        // Team rates from counts, like the fact sheet's.
        let lines = team.activePlayers.compactMap { $0.stats?.batting }
        let pa = lines.reduce(0) { $0 + $1.pa }
        if points.count >= 4, pa > 0 {
            let teamOBP = Double(lines.reduce(0) { $0 + $1.h + $1.bb + $1.hbp }) / Double(pa)
            let teamK = Double(lines.reduce(0) { $0 + $1.so }) / Double(pa)
            VStack(alignment: .leading, spacing: 12) {
                Caption("Hitter Map")
                chart(points, teamOBP: teamOBP, teamK: teamK)
                    .frame(height: 340)
                    .padding(16)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func chart(_ points: [Point], teamOBP: Double, teamK: Double) -> some View {
        Chart {
            RuleMark(x: .value("Team OBP", teamOBP))
                .foregroundStyle(Color.primary.opacity(0.18))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            RuleMark(y: .value("Team K%", teamK))
                .foregroundStyle(Color.primary.opacity(0.18))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(points) { p in
                PointMark(x: .value("OBP", p.obp), y: .value("K%", p.k))
                    .symbolSize(70)
                    .foregroundStyle(p.obp >= teamOBP && p.k <= teamK ? Color.accentColor : Color.primary.opacity(0.55))
                    .annotation(position: .trailing, spacing: 4) {
                        Text(p.name).font(.caption).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: .automatic(includesZero: false))
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartXAxisLabel("On-base %", alignment: .trailing)
        .chartYAxisLabel("Strikeout %", position: .leading, alignment: .bottom)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.rate(v)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.pct(v)) } }
            }
        }
        .chartPlotStyle { plot in
            plot.overlay(alignment: .topTrailing) { corner("Table-setters") }
                .overlay(alignment: .topLeading) { corner("Puts it in play") }
                .overlay(alignment: .bottomTrailing) { corner("Patient, strikes out") }
                .overlay(alignment: .bottomLeading) { corner("Developing") }
        }
    }

    private func corner(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(Color.primary.opacity(0.35)).padding(6)
    }
}
