import SwiftUI
import LineupKit

/// One side of the game in brief: the AI's lead strength and gap, three numbers. Opens that side's tab.
struct SideCard: View {
    let title: String
    let team: Team
    let side: Side
    let factIDs: [String]
    let open: () -> Void

    var body: some View {
        let a = team.assessment
        let sheet = FactSheet.team(team.activePlayers.map(\.snapshot))
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let good = a?.strengths.first(where: { $0.side == side }) { line("Strength", good.title) }
                    if let work = a?.weaknesses.first(where: { $0.side == side }) { line("Work on", work.title) }
                }
                HStack(spacing: 16) {
                    ForEach(factIDs.compactMap { sheet[$0] }, id: \.id) { fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.value).font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Self.isThin(fact) ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            Text(Self.label(fact)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Open \(title)")
    }

    private func line(_ kind: String, _ text: String) -> some View {
        (Text(kind + "  ").foregroundStyle(.secondary).font(.callout) + Text(text).fontWeight(.medium))
            .lineLimit(1)
    }

    /// Two or fewer catchers or pitchers is a real gap.
    private static func isThin(_ fact: Fact) -> Bool {
        (fact.id == "team.catchers" || fact.id == "team.pitchers") && (Int(fact.value) ?? 0) <= 2
    }

    private static func label(_ fact: Fact) -> String {
        switch fact.id {
        case "team.obp": "OBP"
        case "team.k_rate": "K%"
        case "team.sb": "SB"
        case "team.fpct": "FPCT"
        case "team.p.whip": "WHIP"
        case "team.catchers": "CAN CATCH"
        case "team.pitchers": "CAN PITCH"
        default: fact.label
        }
    }
}

/// Where the scouting reports stand: who's covered, who changed since, who failed or has none.
struct PlayersCard: View {
    let team: Team
    @State private var runner = ScoutRunner.shared

    var body: some View {
        let players = team.activePlayers
        let reported = players.filter { $0.assessment != nil }
        let running = players.filter { runner.jobs[$0.uid]?.isActive == true }
        let failed = players.filter { if case .failed = runner.jobs[$0.uid] { true } else { false } }
        let changed = reported.filter { runner.isStale($0) && runner.jobs[$0.uid] == nil }
        let missing = players.filter { $0.assessment == nil && $0.isAssessable && runner.jobs[$0.uid] == nil }

        VStack(alignment: .leading, spacing: 12) {
            Text("Players").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(reported.count)").font(.title3.weight(.semibold).monospacedDigit())
                Text("of \(players.count) scouting reports").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !running.isEmpty { Text("Assessing \(running.count)…").foregroundStyle(.secondary) }
                group("Failed", failed, color: .red)
                group("Changed", changed, color: .secondary)
                group("No report", missing, color: .secondary)
                if running.isEmpty && failed.isEmpty && changed.isEmpty && missing.isEmpty && !reported.isEmpty {
                    Label("All up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func group(_ title: String, _ players: [Player], color: Color) -> some View {
        if !players.isEmpty {
            let names = team.shortNames
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).foregroundStyle(color)
                ForEach(players.prefix(4)) { player in
                    Button(names[player.uid] ?? player.name) { Navigator.shared.openScoutingReport(player) }
                        .buttonStyle(.plain)
                        .help("Open \(player.name)'s scouting report")
                }
                if players.count > 4 { Text("+\(players.count - 4)").foregroundStyle(.tertiary) }
            }
            .lineLimit(1)
        }
    }
}

/// Every player in the part of the order their scouting report recommends, with hitter type and OBP.
/// The Scout's leadoff picks are marked and come first.
struct BattingGroups: View {
    let team: Team
    let ranks: TeamRanks

    var body: some View {
        let players = team.activePlayers
        let unplaced = players.filter { $0.assessment?.battingZone == nil }
        if unplaced.count < players.count {
            VStack(alignment: .leading, spacing: 12) {
                Caption("Batting Order")
                HStack(alignment: .top, spacing: 12) {
                    ForEach(BattingZone.allCases, id: \.self) { zone in
                        column(zone, players.filter { $0.assessment?.battingZone == zone })
                    }
                }
                if !unplaced.isEmpty {
                    (Text("No report  ").foregroundStyle(.tertiary) + Text(unplaced.map(\.name).joined(separator: ", ")).foregroundStyle(.secondary))
                        .font(.callout)
                }
            }
        }
    }

    private func column(_ zone: BattingZone, _ players: [Player]) -> some View {
        let leadoff = team.assessment?.leadoff ?? [], middle = team.assessment?.middleOrder ?? []
        // The Scout's picks for this part of the order lead it: leadoff picks at the top, middle picks in the middle.
        let picks = zone == .top ? leadoff : zone == .middle ? middle : []
        let sorted = players.sorted { a, b in
            let pa = picks.firstIndex(of: a.uid) ?? .max, pb = picks.firstIndex(of: b.uid) ?? .max
            if pa != pb { return pa < pb }
            return (ranks.standing(a.uid, .obp)?.value ?? -1) > (ranks.standing(b.uid, .obp)?.value ?? -1)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(zone.rawValue.capitalized).font(.headline)
                Spacer()
                Text("OBP").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
            }
            if sorted.isEmpty { Text("–").foregroundStyle(.tertiary) }
            ForEach(sorted) { player in
                Button { Navigator.shared.openScoutingReport(player) } label: { row(player, leadoff: leadoff.contains(player.uid)) }
                    .buttonStyle(.plain)
                    .help("Open \(player.name)'s scouting report")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ player: Player, leadoff: Bool) -> some View {
        let obp = ranks.standing(player.uid, .obp)
        let role = player.assessment.map { $0.battingRole.prefix(1).uppercased() + $0.battingRole.dropFirst() } ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(player.name).lineLimit(1)
                    if leadoff {
                        Text("Leadoff").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                if !role.isEmpty { Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Text(obp.map { Metric.obp.format($0.value) } ?? "–")
                .font(.callout.monospacedDigit())
                .foregroundStyle(obp?.rank == nil ? AnyShapeStyle(.tertiary) : (obp!.rank! <= 3 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)))
        }
        .contentShape(Rectangle())
    }
}
