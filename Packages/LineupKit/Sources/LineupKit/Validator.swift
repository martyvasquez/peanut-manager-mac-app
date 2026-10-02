import Foundation

/// One problem (or note) about a lineup. `message` is written for both the coach and the AI's revise step.
public struct Finding: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable, Comparable {
        case info, warning, violation

        private var rank: Int { [.info: 0, .warning: 1, .violation: 2][self]! }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public enum Code: String, Codable, Sendable {
        // Built-in invariants
        case wrongInningCount, emptyPosition, unknownPlayer, unavailablePlayer, duplicatePlayer
        case unaccountedPlayer, ineligiblePosition, lockBroken, pitcherReentry, notEnoughPlayers
        case battingMissingPlayer, battingDuplicate, battingUnknownPlayer, battingAbsentPlayer
        // Coach rules with a typed check
        case rule
    }

    public var id: String { "\(code.rawValue)|\(inning ?? 0)|\(player?.uuidString ?? "")|\(position?.rawValue ?? "")|\(ruleID?.uuidString ?? "")|\(message)" }
    public var severity: Severity
    public var code: Code
    public var message: String
    public var inning: Int?
    public var player: PlayerID?
    public var position: Position?
    public var ruleID: UUID?

    public init(_ severity: Severity, _ code: Code, _ message: String, inning: Int? = nil, player: PlayerID? = nil, position: Position? = nil, ruleID: UUID? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.inning = inning
        self.player = player
        self.position = position
        self.ruleID = ruleID
    }
}

/// Checks lineups in code. This — not the AI's self-report — is the source of truth for compliance.
public enum Validator {
    /// Can any valid defense exist at all? Run before spending tokens.
    /// Problems that hold for every inning are reported once, not once per inning.
    public static func feasibility(_ context: GameContext) -> [Finding] {
        var findings: [Finding] = []
        let innings = Array(1...max(context.innings, 1))
        let short = innings.filter { context.availablePlayers(inning: $0).count < Position.allCases.count }
        if short.count == innings.count {
            let n = context.availablePlayers(inning: 1).count
            findings.append(Finding(.violation, .notEnoughPlayers, "Only \(n) players are coming. You need 9."))
        } else {
            for inning in short {
                findings.append(Finding(.violation, .notEnoughPlayers, "Inning \(inning): only \(context.availablePlayers(inning: inning).count) players are here. You need 9.", inning: inning))
            }
        }
        for position in Position.allCases {
            let missing = innings.filter { inning in
                !short.contains(inning) && !context.availablePlayers(inning: inning).contains { $0.profile.canPlay(position) }
            }
            guard !missing.isEmpty else { continue }
            let what = switch position {
            case .p: "pitch"
            case .c: "catch"
            default: "play \(position.label)"
            }
            if missing.count == innings.count - short.count {
                findings.append(Finding(.violation, .notEnoughPlayers, "Nobody can \(what).", position: position))
            } else {
                let list = missing.map(String.init).joined(separator: ", ")
                findings.append(Finding(.violation, .notEnoughPlayers, "Nobody can \(what) in inning\(missing.count == 1 ? "" : "s") \(list).", position: position))
            }
        }
        return findings
    }

    public static func validateBattingOrder(_ order: [PlayerID], context: GameContext) -> [Finding] {
        var findings: [Finding] = []
        var seen = Set<PlayerID>()
        for id in order {
            guard let player = context.player(id) else {
                findings.append(Finding(.violation, .battingUnknownPlayer, "The batting order includes a player who isn't on the roster.", player: id))
                continue
            }
            if !seen.insert(id).inserted {
                findings.append(Finding(.violation, .battingDuplicate, "\(player.name) appears more than once in the batting order.", player: id))
            }
            if !context.availability(of: id).present {
                findings.append(Finding(.violation, .battingAbsentPlayer, "\(player.name) is not at this game but is in the batting order.", player: id))
            }
        }
        for player in context.presentPlayers where !seen.contains(player.id) {
            findings.append(Finding(.violation, .battingMissingPlayer, "\(player.name) is at the game but missing from the batting order.", player: player.id))
        }
        return findings
    }

    public static func validateDefense(_ lineup: Lineup, context: GameContext) -> [Finding] {
        var findings: [Finding] = []
        if lineup.innings.count != context.innings {
            findings.append(Finding(.violation, .wrongInningCount,
                "The lineup has \(lineup.innings.count) innings but this game has \(context.innings)."))
        }

        for (index, assignment) in lineup.innings.prefix(context.innings).enumerated() {
            let inning = index + 1
            var placements: [PlayerID: [Slot]] = [:]

            for position in Position.allCases {
                guard let id = assignment.positions[position] else {
                    findings.append(Finding(.violation, .emptyPosition, "Inning \(inning): nobody is playing \(position.label).", inning: inning, position: position))
                    continue
                }
                placements[id, default: []].append(.field(position))
                guard let player = context.player(id) else {
                    findings.append(Finding(.violation, .unknownPlayer, "Inning \(inning): \(position.label) is assigned to a player who isn't on the roster.", inning: inning, player: id, position: position))
                    continue
                }
                if !context.availability(of: id).isAvailable(inning: inning) {
                    findings.append(Finding(.violation, .unavailablePlayer, "Inning \(inning): \(player.name) is at \(position.label) but isn't available that inning.", inning: inning, player: id, position: position))
                }
                if !player.profile.canPlay(position) {
                    findings.append(Finding(.violation, .ineligiblePosition, "Inning \(inning): \(player.name) is at \(position.label), which they are marked as unable to play.", inning: inning, player: id, position: position))
                }
            }
            for id in assignment.sitting {
                placements[id, default: []].append(.bench)
                if context.player(id) == nil {
                    findings.append(Finding(.violation, .unknownPlayer, "Inning \(inning): a player who isn't on the roster is listed as sitting.", inning: inning, player: id))
                }
            }

            for (id, slots) in placements where slots.count > 1 {
                let where_ = slots.map(\.description).joined(separator: " and ")
                findings.append(Finding(.violation, .duplicatePlayer, "Inning \(inning): \(context.name(id)) is listed in more than one place (\(where_)).", inning: inning, player: id))
            }

            for player in context.availablePlayers(inning: inning) where placements[player.id] == nil {
                findings.append(Finding(.violation, .unaccountedPlayer, "Inning \(inning): \(player.name) is available but neither fielding nor sitting.", inning: inning, player: player.id))
            }
        }

        findings += lockFindings(lineup, context: context)
        findings += pitcherReentryFindings(lineup, context: context)
        for rule in context.activeRules {
            if let check = rule.check {
                findings += ruleFindings(check, rule: rule, lineup: lineup, context: context)
            }
        }
        return findings
    }

    public static func validate(_ lineup: Lineup, context: GameContext) -> [Finding] {
        validateBattingOrder(lineup.battingOrder, context: context) + validateDefense(lineup, context: context)
    }

    // MARK: - Invariants

    static func lockFindings(_ lineup: Lineup, context: GameContext) -> [Finding] {
        context.locks.compactMap { lock in
            guard lock.inning <= context.innings else { return nil }
            let actual = lineup.slot(of: lock.player, inning: lock.inning)
            guard actual != lock.slot else { return nil }
            return Finding(.violation, .lockBroken,
                "Inning \(lock.inning): \(context.name(lock.player)) is locked at \(lock.slot) but is at \(actual?.description ?? "nowhere").",
                inning: lock.inning, player: lock.player)
        }
    }

    /// Once a pitcher leaves the mound they can't return later in the game.
    static func pitcherReentryFindings(_ lineup: Lineup, context: GameContext) -> [Finding] {
        var findings: [Finding] = []
        var pulled = Set<PlayerID>()
        var previous: PlayerID?
        for (index, assignment) in lineup.innings.enumerated() {
            let pitcher = assignment.positions[.p]
            if let pitcher, pulled.contains(pitcher) {
                findings.append(Finding(.violation, .pitcherReentry,
                    "Inning \(index + 1): \(context.name(pitcher)) pitched earlier, was taken off the mound, and can't return to pitch.",
                    inning: index + 1, player: pitcher, position: .p))
            }
            if let previous, previous != pitcher { pulled.insert(previous) }
            previous = pitcher
        }
        return findings
    }

    // MARK: - Coach rules

    static func ruleFindings(_ check: RuleCheck, rule: TeamRule, lineup: Lineup, context: GameContext) -> [Finding] {
        let innings = Array(lineup.innings.prefix(context.innings).enumerated()).map { ($0.offset + 1, $0.element) }
        var findings: [Finding] = []

        func fail(_ message: String, player: PlayerID? = nil, inning: Int? = nil) {
            findings.append(Finding(.violation, .rule, "Rule \"\(rule.text)\": \(message)", inning: inning, player: player, ruleID: rule.id))
        }

        for player in context.presentPlayers {
            let mine = innings.filter { context.availability(of: player.id).isAvailable(inning: $0.0) }
            let slots = mine.map { ($0.0, $0.1.slot(of: player.id)) }
            let fieldInnings = slots.filter { if case .field = $0.1 { true } else { false } }
            let sits = slots.filter { $0.1 == .bench || $0.1 == nil }
            func count(_ position: Position) -> Int { slots.filter { $0.1 == .field(position) }.count }

            switch check {
            case .minFieldInnings(let n):
                // A player who's only here for fewer innings can't be held to the full number.
                let required = min(n, mine.count)
                if fieldInnings.count < required {
                    fail("\(player.name) fields \(fieldInnings.count) innings (needs \(required)).", player: player.id)
                }
            case .maxSitInnings(let n):
                if sits.count > n { fail("\(player.name) sits \(sits.count) innings (max \(n)).", player: player.id) }
            case .maxConsecutiveSits(let n):
                var run = 0, longest = 0
                for (_, slot) in slots {
                    if slot == .bench || slot == nil { run += 1; longest = max(longest, run) } else { run = 0 }
                }
                if longest > n { fail("\(player.name) sits \(longest) innings in a row (max \(n)).", player: player.id) }
            case .infieldBy(let inning):
                let window = slots.filter { $0.0 <= inning }
                guard !window.isEmpty else { break }
                let playedInfield = window.contains { if case .field(let p) = $0.1 { p.isInfield } else { false } }
                if !playedInfield { fail("\(player.name) hasn't played infield by the end of inning \(inning).", player: player.id) }
            case .maxPitchingInnings(let n):
                let pitched = count(.p)
                if pitched > n { fail("\(player.name) pitches \(pitched) innings (max \(n)).", player: player.id) }
            case .maxCatchingInnings(let n):
                let caught = count(.c)
                if caught > n { fail("\(player.name) catches \(caught) innings (max \(n)).", player: player.id) }
            case .maxInningsAtOnePosition(let n):
                for position in Position.allCases where count(position) > n {
                    fail("\(player.name) plays \(position.label) for \(count(position)) innings (max \(n)).", player: player.id)
                }
            case .catcherCannotPitchAfter(let n):
                if count(.c) >= n && count(.p) > 0 {
                    fail("\(player.name) catches \(count(.c)) innings and also pitches.", player: player.id)
                }
            }
        }
        return findings
    }
}

public extension Array where Element == Finding {
    var violations: [Finding] { filter { $0.severity == .violation } }
    var hasViolations: Bool { contains { $0.severity == .violation } }
}
