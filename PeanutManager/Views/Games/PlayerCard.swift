import SwiftUI
import LineupKit

/// What a coach wants to know about a kid while setting positions: this game so far, where they play,
/// how they field, and pitching or catching when they do either. Everything comes from the roster and season
/// stats, never the AI; a kid without stats just shows less.
struct PlayerCard: View {
    let model: GameModel
    let player: PlayerSnapshot

    private static let scale: CGFloat = 0.72

    var body: some View {
        let ranks = model.game.team?.ranks
        let profile = player.profile

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(player.name).font(.title3.weight(.semibold))
                if let jersey = player.jersey { Text("#\(jersey)").foregroundStyle(.secondary) }
            }

            if let game = thisGame { section("This Game") { Text(game) } }

            field(profile)

            fielding(ranks)

            if profile.canPlay(.p) { pitching(ranks) }
            if profile.canPlay(.c) { catching }

            if !player.notes.isEmpty {
                section("Notes") { Text(player.notes).fixedSize(horizontal: false, vertical: true) }
            }

            if let stored = model.game.team?.players.first(where: { $0.uid == player.id }) {
                Button("Open in Roster") { Navigator.shared.open(stored, tab: .evaluation) }
                    .buttonStyle(.link)
            }
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
    }

    // MARK: Sections

    /// "3 infield · 2 outfield · 1 sitting" across the innings set so far.
    private var thisGame: String? {
        let slots = (1...max(model.game.innings, 1)).compactMap { model.lineup.slot(of: player.id, inning: $0) }
        guard !slots.isEmpty else { return nil }
        let infield = slots.filter { if case .field(let p) = $0 { p.isInfield } else { false } }.count
        let outfield = slots.filter { if case .field(let p) = $0 { p.isOutfield } else { false } }.count
        let sat = slots.filter { $0 == .bench }.count
        return [(infield, "infield"), (outfield, "outfield"), (sat, "sitting")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// The Coach's Evaluation field, small: Best in orange, Plays grey, Doesn't play dashed.
    private func field(_ profile: PositionProfile) -> some View {
        let s = Self.scale
        return ZStack(alignment: .topLeading) {
            FieldDrawing(scale: s)
            ForEach(Position.allCases, id: \.self) { position in
                let p = FieldGeometry.point(FieldGeometry.fielder[position]!)
                FieldPositions.Dot(fit: profile[position], label: position.label, size: 30)
                    .position(x: p.x * s, y: p.y * s)
            }
        }
        .frame(width: FieldGeometry.size.width * s, height: FieldGeometry.size.height * s)
    }

    @ViewBuilder
    private func fielding(_ ranks: TeamRanks?) -> some View {
        let rated = TwoWay.fieldingRatings.filter { player.ratings[$0] != nil }
        let line = player.stats?.fielding
        let played = (line?.innings ?? [:]).filter { $0.value > 0 }.sorted { $0.value > $1.value }
        if !rated.isEmpty || line.map({ $0.tc > 0 }) == true || !played.isEmpty {
            section("Fielding") {
                if let line, line.tc > 0, let fpct = line.fpct {
                    Text("\(Metric.fpct.format(fpct)) fielding" + rank(ranks, .fpct) + " · \(line.tc) chances, \(line.e) errors")
                }
                if !played.isEmpty {
                    Text(played.map { "\($0.key.label) \(Self.innings($0.value))" }.joined(separator: " · ") + " inn")
                }
                ratings(rated)
            }
        }
    }

    @ViewBuilder
    private func pitching(_ ranks: TeamRanks?) -> some View {
        let keys: [RatingKey] = [.pitchControl, .pitchVelocity, .pitchComposure].filter { player.ratings[$0] != nil }
        let line = player.stats?.pitching
        if !keys.isEmpty || line.map({ $0.outs > 0 }) == true {
            section("Pitching") {
                if let line, line.outs > 0 {
                    let rates = [line.era.map { Metric.era.format($0) + " ERA" + rank(ranks, .era) },
                                 line.kPerBF.map { Metric.pitchKRate.format($0) + " K" + rank(ranks, .pitchKRate) }].compactMap { $0 }
                    Text(([line.ipText + " IP"] + rates).joined(separator: " · "))
                }
                ratings(keys)
            }
        }
    }

    @ViewBuilder
    private var catching: some View {
        let outs = player.stats?.fielding?.catcherOuts ?? 0
        let rated = player.ratings[.catcherAbility] != nil
        if outs > 0 || rated {
            section("Catching") {
                if outs > 0 { Text("\(Self.innings(Double(outs) / 3)) innings caught") }
                ratings([.catcherAbility].filter { player.ratings[$0] != nil })
            }
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content().font(.callout)
        }
    }

    private func ratings(_ keys: [RatingKey]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(keys, id: \.self) { key in
                HStack {
                    Text(key.label)
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: "star.fill").font(.system(size: 9))
                                .foregroundStyle(star <= (player.ratings[key] ?? 0) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        }
                    }
                }
            }
        }
    }

    /// " (2nd)" when the kid ranks on the team, else nothing.
    private func rank(_ ranks: TeamRanks?, _ metric: Metric) -> String {
        ranks?.standing(player.id, metric)?.rankText.map { " (\($0))" } ?? ""
    }

    /// 12, or 12⅓ written as "12.1" like a scorebook.
    private static func innings(_ value: Double) -> String {
        let outs = Int((value * 3).rounded())
        return outs % 3 == 0 ? "\(outs / 3)" : "\(outs / 3).\(outs % 3)"
    }
}
