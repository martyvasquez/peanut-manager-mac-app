import SwiftUI
import LineupKit

/// The Scout's view of one player, at the top of the player's page.
struct ScoutingReport: View {
    let player: Player
    @State private var runner = ScoutRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            status
            if !AIService.shared.isReady {
                // Signed out: the sign-in button stands in for the actions; earlier errors don't matter.
            } else if let error = runner.errors[player.uid] {
                Text(error).foregroundStyle(.red).font(.callout)
            } else if case .failed(let message) = runner.jobs[player.uid] {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            if let a = player.assessment {
                report(a)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let job = runner.jobs[player.uid], job.isActive {
            JobStatus(job: job).font(.callout)
        } else if let a = player.assessment {
            TileRow(spacing: 10) {
                let model = AIService.shared.displayName(for: a.model, effort: a.effort)
                let date = a.assessedAt.formatted(date: .abbreviated, time: .omitted)
                Label("AI · \(model) · \(runner.isStale(player) ? "changed since \(date)" : date)", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                    .help("Written by AI from this player's stats and your evaluation")
                if AIService.shared.isReady {
                    Button(runner.isStale(player) ? "Refresh" : "Reassess") { runner.assess(player) }
                        .buttonStyle(.link)
                }
                Spacer()
                Text("\(a.confidence.rawValue.capitalized) confidence")
                    .foregroundStyle(a.confidence == .low ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help(a.confidenceReason)
            }
            .font(.callout)
        } else if player.isAssessable && AIService.shared.isReady {
            Button("Write Scouting Report", systemImage: "sparkles") { runner.assess(player) }
        } else if !runner.isBusy(player) {
            // A scouting report needs both: stats for the AI to read, and AI to write it.
            let first = player.name.components(separatedBy: " ").first ?? player.name
            Unlock(needs: (player.isAssessable ? [] : [.stats]) + (AIService.shared.isReady ? [] : [.ai]), title: "Scouting Report",
                   message: "What \(first) does well, what to work on, and where they fit. AI writes it from GameChanger stats and your evaluation.",
                   team: player.team)
        }
    }

    private func report(_ a: PlayerAssessment) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text(a.snapshot).font(.title3)
                SidedClaims(side: nil, strengths: a.strengths, weaknesses: a.weaknesses, facts: a.facts)
            }

            PageSection("Offense")
            if !a.battingRole.isEmpty {
                Text(battingLine(a)).fixedSize(horizontal: false, vertical: true)
            }
            SidedClaims(side: .offense, strengths: a.strengths, weaknesses: a.weaknesses, facts: a.facts)

            PageSection("Defense")
            if !a.defense.isEmpty {
                SideBySide(spacing: 36) {
                    ScoutFitField(defense: a.defense)
                    fitList(a)
                }
            }
            SidedClaims(side: .defense, strengths: a.strengths, weaknesses: a.weaknesses, facts: a.facts)

            if let eye = a.eyeVsData {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Your Eye vs. the Stats")
                    Text(eye).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !a.development.isEmpty {
                PageSection("Develop")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(a.development.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.focus).fontWeight(.semibold)
                            if !item.drill.isEmpty { Text(item.drill).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Best fit first. Evidence already shown on an earlier row isn't repeated.
    private func fitList(_ a: PlayerAssessment) -> some View {
        let fits = a.defense.sorted { ($0.fit, $0.position) < ($1.fit, $1.position) }
        var seen: Set<String> = []
        let evidence = fits.map { fit -> [String] in
            let fresh = fit.evidence.filter { !seen.contains($0) }
            seen.formUnion(fit.evidence)
            return fresh
        }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            ForEach(Array(fits.enumerated()), id: \.offset) { index, fit in
                GridRow {
                    Text(fit.position.label).font(.body.weight(.semibold)).frame(width: 30, alignment: .leading)
                    Text(fit.fit.label)
                        .foregroundStyle(fit.fit == .strong ? AnyShapeStyle(.tint) : fit.fit == .notRecommended ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fit.reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        EvidenceChips(ids: evidence[index], facts: a.facts)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func battingLine(_ a: PlayerAssessment) -> String {
        var text = a.battingRole.prefix(1).uppercased() + a.battingRole.dropFirst()
        if let zone = a.battingZone { text += " · \(zone.rawValue) of the order" }
        if !a.battingReason.isEmpty { text += ". \(a.battingReason)" }
        return text
    }
}

/// Claims with the real values of the facts they cite.
struct ClaimList: View {
    let title: String
    let claims: [Claim]
    let facts: FactSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !claims.isEmpty { Caption(title) }
            ForEach(Array(claims.enumerated()), id: \.offset) { _, claim in
                VStack(alignment: .leading, spacing: 4) {
                    Text(claim.title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                    Text(claim.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    EvidenceChips(ids: claim.evidence, facts: facts)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Strengths and Work On for one side (nil: claims about the whole player or team). Shows nothing when empty.
struct SidedClaims: View {
    let side: Side?
    let strengths: [Claim]
    let weaknesses: [Claim]
    let facts: FactSheet

    var body: some View {
        let good = strengths.filter { $0.side == side }, work = weaknesses.filter { $0.side == side }
        if !good.isEmpty || !work.isEmpty {
            SideBySide(spacing: 40) {
                if !good.isEmpty { ClaimList(title: "Strengths", claims: good, facts: facts) }
                if !work.isEmpty { ClaimList(title: "Work On", claims: work, facts: facts) }
                // Keep a lone list at half width, on the left.
                if good.isEmpty || work.isEmpty { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
            }
        }
    }
}

/// "OBP .450" chips rendered from the fact sheet, never from the AI's text.
struct EvidenceChips: View {
    let ids: [String]
    let facts: FactSheet
    var limit = 3

    var body: some View {
        let all = ids.compactMap { facts[$0] }
        let shown = all.prefix(limit)
        if !shown.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(shown, id: \.id) { fact in
                    (Text(fact.label + " ").foregroundStyle(.secondary) + Text(fact.value).fontWeight(.semibold))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                if all.count > limit {
                    Text("+\(all.count - limit)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 3)
                        .help(all.dropFirst(limit).map(\.display).joined(separator: "\n"))
                }
            }
        }
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }
}

/// Wraps its children onto new lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, widest) } ?? widest, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

// MARK: - Team

/// Stats & Insights tabs: the one-minute read, each side of the game in depth, and the full table.
enum TeamTab: String, CaseIterable {
    case summary, offense, defense, stats

    var title: String {
        switch self {
        case .summary: "Overview"
        case .offense: "Offense"
        case .defense: "Defense"
        case .stats: "Stats"
        }
    }
}

/// Stats & Insights: the AI's read on the team, offense and defense in depth, and the season stats table.
struct StatsInsightsView: View {
    let team: Team
    @State private var runner = ScoutRunner.shared
    @AppStorage("teamTab") private var tab: TeamTab = .summary
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, PageMargin.horizontal)
                .padding(.top, 28)
                .padding(.bottom, 16)
            if team.activePlayers.isEmpty {
                ContentUnavailableView {
                    Label("No Players Yet", systemImage: "person.3")
                } description: {
                    Text("Add your team first.")
                } actions: {
                    VStack(spacing: 8) {
                        Button("Import from GameChanger…") { importing = true }
                            .buttonStyle(.borderedProminent)
                        Button("Open Roster") { Navigator.shared.section = .roster }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch tab {
                case .summary: page { overview }
                case .offense: page { offense }
                case .defense: page { defense }
                case .stats: StatsView(team: team)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .gameChangerImport(team: team, isPresented: $importing)
        .toolbar(removing: .title)
        .toolbar {
            if tab != .stats && AIService.shared.isReady && hasStats {
                Button(actionTitle, systemImage: "sparkles") { runner.assessTeam(team) }
                    .disabled(runner.teamRuns[team.uid] != nil || !team.activePlayers.contains(where: \.isAssessable) || runner.isTeamCurrent(team))
                    .help(runner.isTeamCurrent(team) ? "Everyone is assessed and the team summary is up to date"
                                                     : "Assess players who are new or changed, then write the team summary")
            }
        }
        #if DEBUG
        .task { if DebugSupport.assessTeam, team.assessment == nil { runner.assessTeam(team) } }
        #endif
    }

    private func page(@ViewBuilder _ makeContent: () -> some View) -> some View {
        let content = makeContent()
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if !AIService.shared.isReady {
                    aiUnlock
                } else if let error = runner.errors[team.uid], runner.teamRuns[team.uid] == nil {
                    HStack(spacing: 12) {
                        Text(error).foregroundStyle(.red)
                        Button("Try Again") { runner.assessTeam(team) }.buttonStyle(.link)
                    }
                }
                content
            }
            .padding(.horizontal, PageMargin.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if DEBUG
        .task {
            if let id = DebugSupport.scrollTo {
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo(id, anchor: .top)
            }
        }
        #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stats & Insights").font(.largeTitle.weight(.bold))
            if !team.activePlayers.isEmpty {
            SideBySide(alignment: .center, spacing: 16) {
                Picker("", selection: $tab) {
                    ForEach(TeamTab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .id(tab)
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                status
            }
            }
        }
    }

    /// Season stats are in for at least one player.
    private var hasStats: Bool { team.activePlayers.contains { $0.stats != nil } }

    /// Without stats there's nothing to rank or chart: what this tab would show, and one step to get it.
    /// With AI set up, stats are also all the AI write-up is waiting on, so the card says so.
    private var importStats: some View {
        let ai = AIService.shared.isReady
        return switch tab {
        case .offense: Unlock(kind: .stats, title: "Hitting Numbers", message: "On-base, strikeouts and steals, hitter groups, and the team's leaders at the plate" + (ai ? ", plus AI's read on your offense." : "."), team: team)
        case .defense: Unlock(kind: .stats, title: "Fielding Numbers", message: "Fielding, pitching and catching numbers, and the team's leaders in the field" + (ai ? ", plus AI's read on your defense." : "."), team: team)
        default: Unlock(kind: .stats, title: ai ? "Team Numbers and Summary" : "Team Numbers",
                        message: "Import your GameChanger season stats to see team numbers, leaders, and where every kid ranks" + (ai ? ". Then AI writes a scouting report on every kid and a team summary." : "."), team: team)
        }
    }

    /// Without AI: what the AI would write on this tab, and everything it needs (stats too, when they're missing).
    private var aiUnlock: some View {
        let needs: [Unlock.Kind] = hasStats ? [.ai] : [.stats, .ai]
        return switch tab {
        case .offense: Unlock(needs: needs, title: "Offense Scouting", message: "What your hitters do well and what to work on. AI writes it from your GameChanger stats.", team: team)
        case .defense: Unlock(needs: needs, title: "Defense Scouting", message: "Who anchors your defense, where it's thin, and what to work on. AI writes it from your GameChanger stats.", team: team)
        default: Unlock(needs: needs, title: "Team Summary", message: "A one-minute read on your team, a scouting report on every kid, and a practice plan. AI writes them from your GameChanger stats.", team: team)
        }
    }

    @ViewBuilder
    private var status: some View {
        if tab == .stats {
            if let imported = team.statsImportedAt {
                Text("GameChanger · imported \(imported.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary)
            }
        } else if let run = runner.teamRuns[team.uid] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(run.writingSummary ? "Writing the team summary…" : "Assessing players · \(run.total - pending) of \(run.total) done")
            }
            .foregroundStyle(.secondary)
        } else if let a = team.assessment {
            let made = "\(AIService.shared.displayName(for: a.model, effort: a.effort)) · \(a.assessedAt.formatted(date: .abbreviated, time: .omitted))"
            Text(runner.isTeamCurrent(team) ? made : made + " · Out of date")
                .foregroundStyle(.secondary)
        }
    }

    /// The one-minute read: the AI's summary, a card per side and one for the players, then the practice plan.
    private var overview: some View {
        let a = team.assessment
        return VStack(alignment: .leading, spacing: 32) {
            if let a {
                Text(a.summary).font(.title3).textSelection(.enabled)
                SidedClaims(side: nil, strengths: a.strengths, weaknesses: a.weaknesses, facts: a.facts)
            } else if runner.teamRuns[team.uid] == nil && AIService.shared.isReady && hasStats {
                Text("No team summary yet. It's written after every player is assessed.")
                    .foregroundStyle(.secondary)
            }
            if !hasStats && a == nil {
                importStats
            } else {
                SideBySide(spacing: 12) {
                    SideCard(title: "Offense", team: team, side: .offense, factIDs: ["team.obp", "team.k_rate", "team.sb"]) { tab = .offense }
                    SideCard(title: "Defense", team: team, side: .defense, factIDs: ["team.fpct", "team.p.whip", "team.catchers"]) { tab = .defense }
                    if AIService.shared.isReady || team.activePlayers.contains(where: { $0.assessment != nil }) { PlayersCard(team: team) }
                }
                TwoWayMap(team: team, ranks: team.ranks)
            }
            if let a, !a.practice.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Caption("Practice Plan")
                    practice(a)
                }
            }
        }
    }

    private var offense: some View {
        let ranks = team.ranks
        let a = team.assessment
        return VStack(alignment: .leading, spacing: 32) {
            if hasStats { TeamNumbers(team: team, ids: TeamNumbers.offense) }
            if let a {
                SidedClaims(side: .offense, strengths: a.strengths, weaknesses: a.weaknesses, facts: a.facts)
            }
            if hasStats {
                BattingGroups(team: team, ranks: ranks)
                HitterMap(team: team, ranks: ranks)
                TeamLeaders(team: team, ranks: ranks, metrics: TeamLeaders.offense)
            } else {
                importStats
            }
        }
    }

    private var defense: some View {
        let ranks = team.ranks
        let a = team.assessment
        return VStack(alignment: .leading, spacing: 32) {
            if hasStats { TeamNumbers(team: team, ids: TeamNumbers.defense) }
            if let a {
                SidedClaims(side: .defense, strengths: a.strengths, weaknesses: a.weaknesses, facts: a.facts)
            }
            SideBySide(spacing: 40) {
                VStack(alignment: .leading, spacing: 12) {
                    Caption("Depth Chart")
                    DepthChart(team: team)
                }
                if let a {
                    VStack(alignment: .leading, spacing: 28) {
                        names("Defensive Core", a.defensiveCore)
                        if !a.defensiveConcerns.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Caption("Concerns")
                                ForEach(a.defensiveConcerns, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                }
            }
            if hasStats { TeamLeaders(team: team, ranks: ranks, metrics: TeamLeaders.defense) } else { importStats }
        }
    }

    /// Players in this run not yet done (waiting, running or retrying).
    private var pending: Int { team.activePlayers.filter { runner.jobs[$0.uid]?.isActive == true }.count }

    private var actionTitle: String {
        let count = runner.needingAssessment(team).count
        if count > 0, team.assessment != nil || count < team.activePlayers.filter(\.isAssessable).count {
            return "Assess \(count) Player\(count == 1 ? "" : "s")"
        }
        return team.assessment == nil ? "Assess Team" : "Update Summary"
    }

    private func practice(_ a: TeamAssessment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(a.practice.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)").font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(.tertiary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(item.focus).fontWeight(.semibold)
                            if item.priority == .high {
                                Text("Priority").font(.caption.weight(.medium)).foregroundStyle(.tint)
                            }
                        }
                        Text(item.drills).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func names(_ title: String, _ ids: [PlayerID]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(title)
            let players = ids.compactMap { id in team.players.first { $0.uid == id } }
            if players.isEmpty { Text("–").foregroundStyle(.tertiary) }
            ForEach(players) { player in
                Button(player.name) { Navigator.shared.openScoutingReport(player) }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Waiting", "Assessing · 1:42", or "Trying again (2 of 3): the model took too long to answer."
struct JobStatus: View {
    let job: ScoutJob

    var body: some View {
        switch job {
        case .waiting:
            Text("Waiting").foregroundStyle(.tertiary)
        case .running(let since):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text("Assessing · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        case .retrying(let attempt, let reason):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Trying again (\(attempt) of 3). \(reason)").foregroundStyle(.secondary).lineLimit(1)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}
