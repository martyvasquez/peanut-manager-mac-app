import SwiftUI
import LineupKit

/// The Scout's view of one player, at the top of the player's page.
struct ScoutingReport: View {
    let player: Player
    @State private var runner = ScoutRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Scouting Report")
                Spacer()
                status
            }
            if let error = runner.errors[player.uid] {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if let a = player.assessment {
                report(a)
            } else if !runner.assessing.contains(player.uid) {
                Text(player.isAssessable ? "Not assessed yet." : "Add ratings, notes or stats first.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if runner.assessing.contains(player.uid) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Assessing…").foregroundStyle(.secondary)
            }
        } else if let a = player.assessment {
            HStack(spacing: 10) {
                Text(runner.isStale(player) ? "Changed since \(a.assessedAt.formatted(date: .abbreviated, time: .omitted))"
                                            : a.assessedAt.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.secondary)
                Button(runner.isStale(player) ? "Refresh" : "Reassess") { runner.assess(player) }
                    .buttonStyle(.link)
            }
            .font(.callout)
        } else if player.isAssessable {
            Button("Assess") { runner.assess(player) }
        }
    }

    private func report(_ a: PlayerAssessment) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(a.snapshot).font(.title3)
                if !a.battingRole.isEmpty {
                    Text(battingLine(a)).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 40) {
                ClaimList(title: "Strengths", claims: a.strengths, facts: a.facts)
                ClaimList(title: "Work On", claims: a.weaknesses, facts: a.facts)
            }

            if !a.defense.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Position Fit")
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                        ForEach(a.defense, id: \.position) { fit in
                            GridRow {
                                Text(fit.position.label).font(.body.weight(.semibold)).frame(width: 30, alignment: .leading)
                                Text(fit.fit.label)
                                    .foregroundStyle(fit.fit == .strong ? AnyShapeStyle(.tint) : fit.fit == .notRecommended ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(fit.reason).foregroundStyle(.secondary)
                                    EvidenceChips(ids: fit.evidence, facts: a.facts)
                                }
                            }
                        }
                    }
                }
            }

            if let eye = a.eyeVsData {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Your Eye vs. the Stats")
                    Text(eye)
                }
            }

            if !a.development.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Development")
                    ForEach(Array(a.development.enumerated()), id: \.offset) { _, item in
                        (Text(item.focus).fontWeight(.medium) + Text(item.drill.isEmpty ? "" : " — \(item.drill)").foregroundStyle(.secondary))
                    }
                }
            }

            Text("\(a.confidence.rawValue.capitalized) confidence. \(a.confidenceReason)")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .textSelection(.enabled)
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
            Caption(title)
            ForEach(Array(claims.enumerated()), id: \.offset) { _, claim in
                VStack(alignment: .leading, spacing: 4) {
                    Text(claim.title).fontWeight(.semibold)
                    Text(claim.detail).foregroundStyle(.secondary)
                    EvidenceChips(ids: claim.evidence, facts: facts)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "OBP .450" chips rendered from the fact sheet, never from the AI's text.
struct EvidenceChips: View {
    let ids: [String]
    let facts: FactSheet

    var body: some View {
        let shown = ids.compactMap { facts[$0] }
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
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
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

/// Full-width team insights: the Scout's read on the team, lineup ideas, the practice plan, and every player in a line.
struct InsightsView: View {
    let team: Team
    @State private var runner = ScoutRunner.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                if let error = runner.errors[team.uid] {
                    Text(error).foregroundStyle(.red)
                }
                if let a = team.assessment {
                    teamReport(a)
                }
                players
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            Button(team.assessment == nil ? "Assess Team" : "Refresh", systemImage: "sparkles") { runner.assessTeam(team) }
                .disabled(runner.teamProgress[team.uid] != nil || !team.activePlayers.contains(where: \.isAssessable))
                .help("Assess players whose stats, ratings or notes changed, then the team")
        }
        #if DEBUG
        .task { if DebugSupport.assessTeam, team.assessment == nil { runner.assessTeam(team) } }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insights").font(.largeTitle.weight(.bold))
            if let progress = runner.teamProgress[team.uid] {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress.done < progress.total ? "Assessing players · \(progress.done) of \(progress.total)" : "Assessing the team…")
                }
                .foregroundStyle(.secondary)
            } else if let a = team.assessment {
                Text("\(ModelLibrary.shared.models.first { $0.id == a.model }?.name ?? a.model) · \(a.assessedAt.formatted(date: .abbreviated, time: .omitted))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Not assessed yet").foregroundStyle(.secondary)
            }
        }
    }

    private func teamReport(_ a: TeamAssessment) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            Text(a.summary).font(.title3).textSelection(.enabled)

            HStack(alignment: .top, spacing: 40) {
                ClaimList(title: "Strengths", claims: a.strengths, facts: a.facts)
                ClaimList(title: "Work On", claims: a.weaknesses, facts: a.facts)
            }

            HStack(alignment: .top, spacing: 40) {
                names("Leadoff", a.leadoff)
                names("Middle of the Order", a.middleOrder)
                names("Defensive Core", a.defensiveCore)
                if !a.defensiveConcerns.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Caption("Concerns")
                        ForEach(a.defensiveConcerns, id: \.self) { Text($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !a.practice.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Caption("Practice Plan")
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
        }
    }

    private func names(_ title: String, _ ids: [PlayerID]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(title)
            let players = ids.compactMap { id in team.players.first { $0.uid == id } }
            if players.isEmpty { Text("–").foregroundStyle(.tertiary) }
            ForEach(players) { Text($0.name) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var players: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Players").padding(.bottom, 10)
            ForEach(team.activePlayers) { player in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(player.jersey.isEmpty ? "–" : player.jersey)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    Text(player.name).fontWeight(.medium).frame(width: 150, alignment: .leading)
                    if runner.assessing.contains(player.uid) {
                        ProgressView().controlSize(.small)
                    } else if let a = player.assessment {
                        Text(a.snapshot).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 12)
                        Text(a.battingZone.map { "\($0.rawValue.capitalized) of order" } ?? "")
                            .font(.callout).foregroundStyle(.tertiary).fixedSize()
                    } else {
                        Text(player.isAssessable ? "Not assessed" : "No ratings, notes or stats").foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                Divider()
            }
        }
    }
}
