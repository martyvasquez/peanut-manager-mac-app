import Foundation
import Testing
@testable import LineupKit

/// Locks that break a rule (or can't all be kept) are caught before the AI is asked, and never sent back to it.
struct LockConflictTests {
    let players = makeTeam()

    func context(_ rules: [RuleCheck], locks: [Lock]) -> GameContext {
        GameContext(innings: 6, players: players, rules: rules.map { TeamRule(text: $0.summary, check: $0) }, locks: locks)
    }

    func locks(_ player: Int, _ slot: Slot, innings: ClosedRange<Int>) -> [Lock] {
        innings.map { Lock(inning: $0, player: players[player].id, slot: slot) }
    }

    @Test func lockedPitcherOverTheLimitIsAConflict() throws {
        let ctx = context([.maxPitchingInnings(2)], locks: locks(0, .field(.p), innings: 1...3))
        let conflicts = Validator.lockConflicts(ctx)
        let conflict = try #require(conflicts.first)
        #expect(conflicts.count == 1)
        #expect(conflict.severity == .warning)
        #expect(conflict.ruleID == ctx.rules[0].id)
        #expect(conflict.message == "Player 1 is locked at P in innings 1, 2 and 3, but no player pitches more than 2 innings.")
    }

    @Test func locksWithinTheRulesAreFine() {
        let rules: [RuleCheck] = [.maxPitchingInnings(2), .minFieldInnings(3), .infieldBy(inning: 4), .maxConsecutiveSits(1)]
        let ctx = context(rules, locks: locks(0, .field(.p), innings: 1...2) + locks(5, .bench, innings: 1...1) + locks(5, .field(.lf), innings: 2...3))
        #expect(Validator.lockConflicts(ctx).isEmpty)
    }

    @Test func lockedSitsThatLeaveTooFewFieldInningsAreAConflict() {
        #expect(Validator.lockConflicts(context([.minFieldInnings(3)], locks: locks(5, .bench, innings: 1...3))).isEmpty)
        let conflicts = Validator.lockConflicts(context([.minFieldInnings(3)], locks: locks(5, .bench, innings: 1...4)))
        #expect(conflicts.map(\.message) == ["Player 6 is locked to sit in innings 1, 2, 3 and 4, but every player fields at least 3 innings."])
    }

    @Test func lockedOutOfTheInfieldThroughTheDeadlineIsAConflict() {
        #expect(Validator.lockConflicts(context([.infieldBy(inning: 4)], locks: locks(5, .field(.lf), innings: 1...3))).isEmpty)
        #expect(Validator.lockConflicts(context([.infieldBy(inning: 4)], locks: locks(5, .field(.lf), innings: 1...4))).count == 1)
    }

    @Test func lockedSitsInARowAreAConflict() {
        let conflicts = Validator.lockConflicts(context([.maxConsecutiveSits(1)], locks: locks(5, .bench, innings: 2...3)))
        #expect(conflicts.map(\.message) == ["Player 6 is locked to sit in innings 2 and 3, but no player sits more than 1 innings in a row."])
    }

    @Test func twoPlayersLockedIntoOneSpotIsAConflict() {
        let ctx = context([], locks: [Lock(inning: 2, player: players[5].id, slot: .field(.ss)), Lock(inning: 2, player: players[6].id, slot: .field(.ss))])
        #expect(Validator.lockConflicts(ctx).map(\.message) == ["Inning 2: Player 6 and Player 7 are both locked at SS."])
    }

    @Test func lockedPitcherReturningIsAConflict() {
        let ctx = context([], locks: [Lock(inning: 1, player: players[0].id, slot: .field(.p)), Lock(inning: 2, player: players[1].id, slot: .field(.p)), Lock(inning: 3, player: players[0].id, slot: .field(.p))])
        #expect(Validator.lockConflicts(ctx).count == 1)
    }

    @Test func excusingDowngradesOnlyTheConflict() {
        var lineup = validLineup(players)
        lineup.innings[2].assign(players[0].id, to: .field(.p))
        // Player 1 pitches innings 1–3 because the coach locked it; the catchers break a rule on their own.
        let ctx = context([.maxPitchingInnings(2), .maxCatchingInnings(2)], locks: locks(0, .field(.p), innings: 1...3))
        let findings = Validator.excusing(Validator.validateDefense(lineup, context: ctx), conflicts: Validator.lockConflicts(ctx))
        let pitching = findings.filter { $0.ruleID == ctx.rules[0].id }
        #expect(pitching.count == 1 && pitching.allSatisfy { $0.severity == .warning })
        #expect(findings.filter { $0.ruleID == ctx.rules[1].id }.allSatisfy { $0.severity == .violation })
        #expect(findings.violations.count == 2)
    }

    @Test func engineDoesNotAskTheAIToFixAConflict() async throws {
        var lineup = validLineup(players)
        lineup.innings[2].assign(players[0].id, to: .field(.p))
        let ctx = context([.maxPitchingInnings(2)], locks: locks(0, .field(.p), innings: 1...3))
        let client = ScriptedClient([defenseJSON(lineup, players: players)])
        let result = try await LineupEngine(client: client, model: "m").defense(ctx, battingOrder: players.map(\.id))
        #expect(client.requests.count == 1)
        #expect(result.revisions == 0)
        #expect(!result.findings.hasViolations)
        #expect(result.findings.contains { $0.code == .rule && $0.severity == .warning })
    }
}
