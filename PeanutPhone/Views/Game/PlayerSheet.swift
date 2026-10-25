import SwiftUI
import SwiftData
import LineupKit

/// A kid at a glance, from the game: this game so far, then the season at the plate or in the field (whichever
/// the coach is working on comes first). The Mac's `PlayerCard` and `BattingCard` in one sheet. Everything comes
/// from the roster and season stats, never the AI; a kid without stats shows less, and the way to add them.
struct PlayerSheet: View {
    enum Focus: Identifiable { case batting, fielding; var id: Self { self } }

    let model: GameModel
    let player: PlayerSnapshot
    let focus: Focus
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        let team = model.game.team
        let ranks = TeamRanks((team?.activePlayers ?? []).map { ($0.uid, $0.stats) })
        let stored = team?.players.first { $0.uid == player.id }
        let batting = player.stats?.batting.flatMap { $0.pa > 0 ? $0 : nil }
        NavigationStack {
            List {
                if let game = thisGame {
                    Section("This Game") { Text(game) }
                }
                switch focus {
                case .batting:
                    hitting(batting, ranks)
                    fieldingSections(ranks)
                case .fielding:
                    fieldingSections(ranks)
                    hitting(batting, ranks)
                }
                if player.stats == nil {
                    Section {
                        Button("Import GameChanger Stats", systemImage: "square.and.arrow.down") { importing = true }
                    } header: {
                        Text("Season Stats")
                    } footer: {
                        Text("AVG, OBP, fielding % and where \(firstName) ranks on the team.")
                    }
                }
                if !player.notes.isEmpty {
                    Section("Notes") { Text(player.notes) }
                }
                if let stored {
                    Section {
                        NavigationLink("Edit Player") { PlayerEditor(player: stored) }
                    }
                }
            }
            .navigationTitle(player.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text(player.name).font(.headline)
                        if let jersey = player.jersey { Text("#\(jersey)").foregroundStyle(.secondary) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .gameChangerImport(team: team, isPresented: $importing)
        }
        .presentationDetents([.medium, .large])
    }

    private var firstName: String { player.name.split(separator: " ").first.map(String.init) ?? player.name }

    // MARK: This game

    /// "Batting 3rd · 3 infield · 2 outfield · 1 sitting", from what's set so far.
    private var thisGame: String? {
        var parts: [String] = []
        if let spot = model.lineup.battingOrder.firstIndex(of: player.id) { parts.append("Batting \(Standing.ordinal(spot + 1))") }
        let slots = (1...max(model.game.innings, 1)).compactMap { model.lineup.slot(of: player.id, inning: $0) }
        let infield = slots.filter { if case .field(let p) = $0 { p.isInfield } else { false } }.count
        let outfield = slots.filter { if case .field(let p) = $0 { p.isOutfield } else { false } }.count
        let sat = slots.filter { $0 == .bench }.count
        parts += [(infield, "infield"), (outfield, "outfield"), (sat, "sitting")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Hitting

    @ViewBuilder
    private func hitting(_ line: BattingLine?, _ ranks: TeamRanks) -> some View {
        let rated = [RatingKey.plateDiscipline, .contactAbility, .battingPower, .runSpeed].filter { player.ratings[$0] != nil }
        if let line {
            Section("Hitting") {
                // AVG, OBP and SLG large with their team ranks (top three in the accent color).
                HStack(alignment: .top, spacing: 0) {
                    ForEach([Metric.avg, .obp, .slg], id: \.self) { metric in
                        let standing = ranks.standing(player.id, metric)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(standing.map { metric.format($0.value) } ?? "–").font(.title2.monospacedDigit())
                            Text([metric.label, standing?.rankText].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(standing?.rank.map { $0 <= 3 } == true ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(counts(line)).foregroundStyle(.secondary)
                let rates = [Metric.kRate, .bbRate].compactMap { metric in
                    ranks.standing(player.id, metric).map { "\(metric.format($0.value)) \(metric.label)" + ($0.rankText.map { " (\($0))" } ?? "") }
                }
                if !rates.isEmpty { Text(rates.joined(separator: " · ")) }
                if line.sb + line.cs > 0 {
                    let rank = ranks.standing(player.id, .sb)?.rankText.map { " (\($0))" } ?? ""
                    Text(["\(line.sb) SB" + rank, line.sbPct.map { "\(Int(($0 * 100).rounded()))% success" }].compactMap { $0 }.joined(separator: " · "))
                }
                if ranks.standing(player.id, .avg)?.rank == nil {
                    Text("Too few plate appearances to rank").foregroundStyle(.tertiary)
                }
                StarLines(keys: rated, ratings: player.ratings)
            }
        } else if !rated.isEmpty {
            Section("Hitting") { StarLines(keys: rated, ratings: player.ratings) }
        }
    }

    /// "33 PA · 20 H · 4 2B · 1 HR · 6 BB · 3 K"
    private func counts(_ line: BattingLine) -> String {
        var counts = ["\(line.pa) PA", "\(line.h) H"]
        if line.doubles > 0 { counts.append("\(line.doubles) 2B") }
        if line.triples > 0 { counts.append("\(line.triples) 3B") }
        if line.hr > 0 { counts.append("\(line.hr) HR") }
        counts += ["\(line.bb) BB", "\(line.so) K"]
        return counts.joined(separator: " · ")
    }

    // MARK: Fielding

    @ViewBuilder
    private func fieldingSections(_ ranks: TeamRanks) -> some View {
        let profile = player.profile
        Section("Positions") {
            let scale: CGFloat = 0.8
            ZStack(alignment: .topLeading) {
                FieldDrawing(scale: scale)
                ForEach(Position.allCases, id: \.self) { position in
                    let p = FieldGeometry.point(FieldGeometry.fielder[position]!)
                    FieldPositions.Dot(fit: profile[position], label: position.label, size: 34)
                        .position(x: p.x * scale, y: p.y * scale)
                }
            }
            .frame(width: FieldGeometry.size.width * scale, height: FieldGeometry.size.height * scale)
            .frame(maxWidth: .infinity)
        }
        fielding(ranks)
        if profile.canPlay(.p) { pitching(ranks) }
        if profile.canPlay(.c) { catching }
    }

    @ViewBuilder
    private func fielding(_ ranks: TeamRanks) -> some View {
        let rated = TwoWay.fieldingRatings.filter { player.ratings[$0] != nil }
        let line = player.stats?.fielding
        let played = (line?.innings ?? [:]).filter { $0.value > 0 }.sorted { $0.value > $1.value }
        if !rated.isEmpty || line.map({ $0.tc > 0 }) == true || !played.isEmpty {
            Section("Fielding") {
                if let line, line.tc > 0, let fpct = line.fpct {
                    Text("\(Metric.fpct.format(fpct)) fielding" + rank(ranks, .fpct) + " · \(line.tc) chances, \(line.e) errors")
                }
                if !played.isEmpty {
                    Text(played.map { "\($0.key.label) \(Self.innings($0.value))" }.joined(separator: " · ") + " inn")
                }
                StarLines(keys: rated, ratings: player.ratings)
            }
        }
    }

    @ViewBuilder
    private func pitching(_ ranks: TeamRanks) -> some View {
        let keys: [RatingKey] = [.pitchControl, .pitchVelocity, .pitchComposure].filter { player.ratings[$0] != nil }
        let line = player.stats?.pitching
        if !keys.isEmpty || line.map({ $0.outs > 0 }) == true {
            Section("Pitching") {
                if let line, line.outs > 0 {
                    let rates = [line.era.map { Metric.era.format($0) + " ERA" + rank(ranks, .era) },
                                 line.kPerBF.map { Metric.pitchKRate.format($0) + " K" + rank(ranks, .pitchKRate) }].compactMap { $0 }
                    Text(([line.ipText + " IP"] + rates).joined(separator: " · "))
                }
                StarLines(keys: keys, ratings: player.ratings)
            }
        }
    }

    @ViewBuilder
    private var catching: some View {
        let outs = player.stats?.fielding?.catcherOuts ?? 0
        let rated = [RatingKey.catcherAbility].filter { player.ratings[$0] != nil }
        if outs > 0 || !rated.isEmpty {
            Section("Catching") {
                if outs > 0 { Text("\(Self.innings(Double(outs) / 3)) innings caught") }
                StarLines(keys: rated, ratings: player.ratings)
            }
        }
    }

    /// " (2nd)" when the kid ranks on the team, else nothing.
    private func rank(_ ranks: TeamRanks, _ metric: Metric) -> String {
        ranks.standing(player.id, metric)?.rankText.map { " (\($0))" } ?? ""
    }

    /// 12, or 12⅓ written as "12.1" like a scorebook.
    private static func innings(_ value: Double) -> String {
        let outs = Int((value * 3).rounded())
        return outs % 3 == 0 ? "\(outs / 3)" : "\(outs / 3).\(outs % 3)"
    }
}

/// The coach's 1–5 star ratings, one row each.
struct StarLines: View {
    let keys: [RatingKey]
    let ratings: Ratings

    var body: some View {
        ForEach(keys, id: \.self) { key in
            HStack {
                Text(key.label)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: "star.fill").font(.caption2)
                            .foregroundStyle(star <= (ratings[key] ?? 0) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(key.label): \(ratings[key].map { "\($0) stars" } ?? "unrated")")
        }
    }
}
