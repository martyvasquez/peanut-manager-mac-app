import Foundation
import Observation
import LineupKit

/// The spike's game: the sample team and its recorded lineup, in memory only.
/// Edits follow `GameModel`: a hand placement is a lock, a taken spot swaps, and a full inning seats everyone else.
@Observable
final class SpikeModel {
    struct State: Hashable {
        var lineup: Lineup
        var locks: [Lock]
        var provenance: [CellKey: Provenance]
    }

    let innings: Int
    let opponent: String
    private(set) var players: [PlayerSnapshot]
    private(set) var rules: [TeamRule]
    private(set) var state: State
    private var history: [State] = []
    /// Counts swaps, so the grid can play a haptic on each one.
    private(set) var swaps = 0

    init(innings: Int, opponent: String, players: [PlayerSnapshot], rules: [TeamRule], lineup: Lineup) {
        self.innings = innings
        self.opponent = opponent
        self.players = players
        self.rules = rules
        var lineup = lineup
        lineup.resize(innings: innings)
        var provenance: [CellKey: Provenance] = [:]
        for (index, inning) in lineup.innings.enumerated() {
            for id in inning.positions.values { provenance[CellKey(inning: index + 1, player: id)] = .ai }
        }
        state = State(lineup: lineup, locks: [], provenance: provenance)
    }

    var lineup: Lineup { state.lineup }
    var context: GameContext { GameContext(innings: innings, players: players, rules: rules, locks: state.locks, ageGroup: "10U") }

    /// The batting order, then anyone not in it.
    var rows: [PlayerSnapshot] {
        let byID = Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0) })
        let ordered = lineup.battingOrder.compactMap { byID[$0] }
        return ordered + players.filter { !lineup.battingOrder.contains($0.id) }
    }

    var isFilled: Bool { lineup.isFullyPositioned }
    var canUndo: Bool { !history.isEmpty }

    var findings: [Finding] {
        let ctx = context
        if isFilled {
            return Validator.excusing(Validator.validateDefense(lineup, context: ctx), conflicts: Validator.lockConflicts(ctx))
        }
        return Validator.liveRuleFindings(lineup, context: ctx)
    }

    var openSpots: Int { lineup.innings.reduce(0) { $0 + $1.openPositions.count } }

    func slot(_ key: CellKey) -> Slot? { lineup.slot(of: key.player, inning: key.inning) }
    func isLocked(_ key: CellKey) -> Bool { state.locks.contains { $0.inning == key.inning && $0.player == key.player } }
    func provenance(_ key: CellKey) -> Provenance? { state.provenance[key] }

    /// Kids sitting this inning are available but not placed: in no position and not on the bench.
    func unplaced(inning: Int) -> [PlayerSnapshot] {
        let assignment = lineup.innings[inning - 1]
        return context.availablePlayers(inning: inning).filter { assignment.slot(of: $0.id) == nil }
    }

    // MARK: Edits

    func assign(_ player: PlayerID, to slot: Slot, inning: Int) {
        let available = context.availablePlayers(inning: inning).map(\.id)
        mutate { s in
            let displaced: PlayerID? = if case .field(let position) = slot { s.lineup.innings[inning - 1].positions[position] } else { nil }
            s.lineup.assign(player, to: slot, inning: inning)
            s.lineup.innings[inning - 1].seatRest(available: available)
            s.locks.removeAll { $0.inning == inning && ($0.player == player || $0.player == displaced) }
            s.locks.append(Lock(inning: inning, player: player, slot: slot))
            s.provenance[CellKey(inning: inning, player: player)] = .coach
            if let displaced { s.provenance[CellKey(inning: inning, player: displaced)] = .coach }
        }
    }

    func canSwap(_ a: PlayerID, _ b: PlayerID, inning: Int) -> Bool {
        let ctx = context
        guard a != b, ctx.availability(of: a).isAvailable(inning: inning), ctx.availability(of: b).isAvailable(inning: inning) else { return false }
        func fits(_ id: PlayerID, _ slot: Slot?) -> Bool {
            guard case .field(let position) = slot else { return true }
            return ctx.player(id)?.profile.canPlay(position) ?? false
        }
        return fits(a, lineup.slot(of: b, inning: inning)) && fits(b, lineup.slot(of: a, inning: inning))
    }

    func swap(_ a: PlayerID, _ b: PlayerID, inning: Int) {
        let available = context.availablePlayers(inning: inning).map(\.id)
        mutate { s in
            s.lineup.innings[inning - 1].swap(a, b)
            s.lineup.innings[inning - 1].seatRest(available: available)
            s.locks.removeAll { $0.inning == inning && ($0.player == a || $0.player == b) }
            for id in [a, b] {
                guard let slot = s.lineup.slot(of: id, inning: inning) else { continue }
                s.locks.append(Lock(inning: inning, player: id, slot: slot))
                s.provenance[CellKey(inning: inning, player: id)] = .coach
            }
        }
        swaps += 1
    }

    func toggleLock(_ key: CellKey) {
        guard let slot = slot(key) else { return }
        let locked = isLocked(key)
        mutate { s in
            if locked {
                s.locks.removeAll { $0.inning == key.inning && $0.player == key.player }
            } else {
                s.locks.append(Lock(inning: key.inning, player: key.player, slot: slot))
            }
        }
    }

    func clearPositions() {
        mutate { s in
            s.lineup.innings = s.lineup.innings.map { _ in InningAssignment() }
            s.locks = []
            s.provenance = [:]
        }
    }

    func undo() {
        guard let last = history.popLast() else { return }
        state = last
    }

    private func mutate(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        history.append(state)
        state = next
    }
}

// MARK: - Sample

extension SpikeModel {
    /// The bundled sample team (anonymized GameChanger export) and the lineup recorded for it, as in `SampleData`.
    static func sample() -> SpikeModel {
        let best: [[Position]] = [[.first], [.p], [.ss], [.third], [.second], [.lf], [.cf], [.c], [.rf], [], [.cf], []]
        struct Recorded: Decodable {
            struct Entry: Decodable { let name: String; let id: UUID }
            struct Document: Decodable { let lineup: Lineup }
            let players: [Entry]
            let lineup: Document
        }
        let csv = Bundle.main.url(forResource: "sample-team", withExtension: "csv").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let recorded = Bundle.main.url(forResource: "sample-ai", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Recorded.self, from: $0) }
        let ids = Dictionary((recorded?.players ?? []).map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })

        let rows = (try? GameChangerImport.parse(csv)) ?? []
        let players = rows.enumerated().map { index, row in
            // GameChanger history, as `Player.applyGameChangerHistory`, then the sample's made-up best positions.
            var profile = PositionProfile.default
            if row.pitching.outs > 0 { profile[.p] = .can }
            if row.fielding.catcherOuts > 0 || (row.fielding.innings[.c] ?? 0) > 0 { profile[.c] = .can }
            if let top = row.fielding.innings.filter({ $0.value > 0 }).max(by: { $0.value < $1.value })?.key { profile[top] = .primary }
            for position in best[safe: index] ?? [] where profile.canPlay(position) { profile[position] = .primary }
            return PlayerSnapshot(
                id: ids[row.fullName] ?? UUID(), name: row.fullName, jersey: row.number, profile: profile,
                stats: PlayerStats(batting: row.batting, fielding: row.fielding, pitching: row.pitching)
            )
        }
        let rules = [
            TeamRule(text: "Every player must play at least 3 innings in the field.", check: .minFieldInnings(3)),
            TeamRule(text: "Players must sit out at most 1 inning in a row.", check: .maxConsecutiveSits(1)),
            TeamRule(text: "All players must play an infield position by the end of the 4th inning.", check: .infieldBy(inning: 4)),
            TeamRule(text: "No player can pitch more than 2 innings.", check: .maxPitchingInnings(2)),
        ]
        var lineup = recorded?.lineup.lineup ?? Lineup(battingOrder: players.map(\.id))
        if UserDefaults.standard.bool(forKey: "PMEmpty") { lineup.innings = [] }
        return SpikeModel(innings: 6, opponent: "Sample Opponent", players: players, rules: rules, lineup: lineup)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension PlayerSnapshot {
    /// "Alex R.": enough to tell kids apart in a narrow column.
    var shortName: String {
        let parts = name.split(separator: " ")
        guard let first = parts.first else { return name }
        guard parts.count > 1, let initial = parts.last?.first else { return String(first) }
        return "\(first) \(initial)."
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}
