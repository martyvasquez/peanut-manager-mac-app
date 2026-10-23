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
        // The coach's locks can't all be kept, or keeping them breaks a rule
        case lockConflict
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

    // MARK: - Lock conflicts

    /// Problems the coach's locks cause by themselves, whatever the AI does: a rule the locked spots already
    /// break (or leave no room to meet), two players locked into one spot, a lock the player can't fill.
    /// Only the coach can fix these. Each is a warning: the coach may fill anyway on purpose.
    public static func lockConflicts(_ context: GameContext) -> [Finding] {
        let locks = context.locks.filter { $0.inning <= context.innings }
        guard !locks.isEmpty else { return [] }
        var findings: [Finding] = []
        func conflict(_ message: String, inning: Int? = nil, player: PlayerID? = nil, position: Position? = nil, rule: UUID? = nil) {
            findings.append(Finding(.warning, .lockConflict, message, inning: inning, player: player, position: position, ruleID: rule))
        }

        // Locks the grid can't hold.
        for inning in Set(locks.map(\.inning)).sorted() {
            let here = locks.filter { $0.inning == inning }
            for position in Position.allCases {
                let same = here.filter { $0.slot == .field(position) }
                if same.count > 1 {
                    conflict("Inning \(inning): \(names(same.map(\.player), context)) are \(same.count == 2 ? "both" : "all") locked at \(position.label).", inning: inning, position: position)
                }
            }
            for lock in here {
                guard let player = context.player(lock.player) else { continue }
                if !context.availability(of: lock.player).isAvailable(inning: inning) {
                    conflict("\(player.name) is locked at \(lock.slot) in inning \(inning) but isn't here then.", inning: inning, player: lock.player)
                } else if case .field(let position) = lock.slot, !player.profile.canPlay(position) {
                    conflict("\(player.name) is locked at \(position.label) in inning \(inning) but is marked as unable to play it.", inning: inning, player: lock.player, position: position)
                }
            }
        }

        // A pitcher locked back on the mound after someone else was locked there.
        for player in context.presentPlayers {
            let pitched = locks.filter { $0.player == player.id && $0.slot == .field(.p) }.map(\.inning).sorted()
            guard let first = pitched.first, let last = pitched.last, last > first else { continue }
            if locks.contains(where: { $0.player != player.id && $0.slot == .field(.p) && $0.inning > first && $0.inning < last }) {
                conflict("\(player.name) is locked to pitch innings \(list(pitched)) with someone else pitching in between, and a pitcher can't return.", player: player.id, position: .p)
            }
        }

        // Rules the locked spots already break, or leave no room to meet.
        for rule in context.activeRules {
            guard let check = rule.check else { continue }
            let because = check.summary.prefix(1).lowercased() + check.summary.dropFirst()
            for player in context.presentPlayers {
                let mine = (1...max(context.innings, 1)).filter { context.availability(of: player.id).isAvailable(inning: $0) }
                let locked = locks.filter { $0.player == player.id && mine.contains($0.inning) }
                func innings(_ slot: Slot) -> [Int] { locked.filter { $0.slot == slot }.map(\.inning).sorted() }
                let sits = innings(.bench)
                func fail(_ what: String) {
                    conflict("\(player.name) is \(what), but \(because).", player: player.id, rule: rule.id)
                }

                switch check {
                case .maxPitchingInnings(let n):
                    if innings(.field(.p)).count > n { fail("locked at P in innings \(list(innings(.field(.p))))") }
                case .maxCatchingInnings(let n):
                    if innings(.field(.c)).count > n { fail("locked at C in innings \(list(innings(.field(.c))))") }
                case .maxInningsAtOnePosition(let n):
                    for position in Position.allCases where innings(.field(position)).count > n {
                        fail("locked at \(position.label) in innings \(list(innings(.field(position))))")
                    }
                case .catcherCannotPitchAfter(let n):
                    if innings(.field(.c)).count >= n && !innings(.field(.p)).isEmpty {
                        fail("locked at C in innings \(list(innings(.field(.c)))) and at P in \(innings(.field(.p)).count == 1 ? "inning" : "innings") \(list(innings(.field(.p))))")
                    }
                case .maxSitInnings(let n):
                    if sits.count > n { fail("locked to sit in innings \(list(sits))") }
                case .maxConsecutiveSits(let n):
                    var run: [Int] = [], longest: [Int] = []
                    for inning in mine {
                        if sits.contains(inning) { run.append(inning) } else { run = [] }
                        if run.count > longest.count { longest = run }
                    }
                    if longest.count > n { fail("locked to sit in innings \(list(longest))") }
                case .minFieldInnings(let n):
                    if mine.count - sits.count < min(n, mine.count) { fail("locked to sit in innings \(list(sits))") }
                case .infieldBy(let inning):
                    let window = mine.filter { $0 <= inning }
                    guard !window.isEmpty else { break }
                    let lockedHere = locked.filter { $0.inning <= inning }
                    let canStillPlayInfield = lockedHere.count < window.count
                        || lockedHere.contains { if case .field(let p) = $0.slot { p.isInfield } else { false } }
                    if !canStillPlayInfield { fail("locked in the outfield or on the bench every inning through \(inning)") }
                }
            }
        }
        return findings
    }

    /// The same findings, with the ones the coach's locks make unavoidable turned into warnings: the AI isn't
    /// asked to fix them, and they don't count against the lineup.
    public static func excusing(_ findings: [Finding], conflicts: [Finding]) -> [Finding] {
        guard !conflicts.isEmpty else { return findings }
        return findings.map { finding in
            guard finding.severity == .violation else { return finding }
            let excused = conflicts.contains { c in
                switch finding.code {
                case .rule: c.ruleID != nil && c.ruleID == finding.ruleID && c.player == finding.player
                case .pitcherReentry: c.ruleID == nil && c.player == finding.player && c.position == .p && c.inning == nil
                case .ineligiblePosition, .unavailablePlayer:
                    c.ruleID == nil && c.inning == finding.inning && c.player == finding.player
                case .lockBroken:
                    // Two players locked into one spot: one of them can't be where they're locked.
                    c.ruleID == nil && c.inning == finding.inning && (c.player == finding.player || c.player == nil)
                default: false
                }
            }
            guard excused else { return finding }
            var warning = finding
            warning.severity = .warning
            return warning
        }
    }

    static func list(_ innings: [Int]) -> String {
        let text = innings.map(String.init)
        guard text.count > 1 else { return text.first ?? "" }
        return text.dropLast().joined(separator: ", ") + " and " + text.last!
    }

    static func names(_ ids: [PlayerID], _ context: GameContext) -> String {
        let names = ids.map { context.name($0) }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
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

    /// Rule checks on a lineup the coach is still building: an empty spot is undecided, not a sit, so only
    /// what's already broken is reported (a limit passed, or too few open spots left to reach a minimum).
    public static func liveRuleFindings(_ lineup: Lineup, context: GameContext) -> [Finding] {
        context.activeRules.flatMap { rule in
            rule.check.map { ruleFindings($0, rule: rule, lineup: lineup, context: context, settled: false) } ?? []
        }
    }

    /// `settled` false: empty spots may still be filled either way (see `liveRuleFindings`).
    static func ruleFindings(_ check: RuleCheck, rule: TeamRule, lineup: Lineup, context: GameContext, settled: Bool = true) -> [Finding] {
        let innings = Array(lineup.innings.prefix(context.innings).enumerated()).map { ($0.offset + 1, $0.element) }
        var findings: [Finding] = []

        func fail(_ message: String, player: PlayerID? = nil, inning: Int? = nil) {
            findings.append(Finding(.violation, .rule, "Rule \"\(rule.text)\": \(message)", inning: inning, player: player, ruleID: rule.id))
        }

        for player in context.presentPlayers {
            let mine = innings.filter { context.availability(of: player.id).isAvailable(inning: $0.0) }
            let slots = mine.map { ($0.0, $0.1.slot(of: player.id)) }
            let fieldInnings = slots.filter { if case .field = $0.1 { true } else { false } }
            let sits = slots.filter { $0.1 == .bench || (settled && $0.1 == nil) }
            let open = settled ? 0 : slots.filter { $0.1 == nil }.count
            func count(_ position: Position) -> Int { slots.filter { $0.1 == .field(position) }.count }

            switch check {
            case .minFieldInnings(let n):
                // A player who's only here for fewer innings can't be held to the full number.
                let required = min(n, mine.count)
                if fieldInnings.count + open < required {
                    fail("\(player.name) fields \(fieldInnings.count) innings (needs \(required)).", player: player.id)
                }
            case .maxSitInnings(let n):
                if sits.count > n { fail("\(player.name) sits \(sits.count) innings (max \(n)).", player: player.id) }
            case .maxConsecutiveSits(let n):
                var run = 0, longest = 0
                for (_, slot) in slots {
                    if slot == .bench || (settled && slot == nil) { run += 1; longest = max(longest, run) } else { run = 0 }
                }
                if longest > n { fail("\(player.name) sits \(longest) innings in a row (max \(n)).", player: player.id) }
            case .infieldBy(let inning):
                let window = slots.filter { $0.0 <= inning }
                guard !window.isEmpty else { break }
                let playedInfield = window.contains { if case .field(let p) = $0.1 { p.isInfield } else { false } }
                let stillOpen = !settled && window.contains { $0.1 == nil }
                if !playedInfield && !stillOpen { fail("\(player.name) hasn't played infield by the end of inning \(inning).", player: player.id) }
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
