import Foundation
import Testing
@testable import LineupKit

struct ValidatorTests {
    let players = makeTeam()
    var context: GameContext { GameContext(innings: 6, players: players) }

    @Test func validLineupHasNoFindings() {
        #expect(Validator.validate(validLineup(players), context: context).isEmpty)
    }

    @Test func emptyPositionIsCaught() {
        var lineup = validLineup(players)
        lineup.innings[2].positions[.ss] = nil
        let codes = Validator.validateDefense(lineup, context: context).map(\.code)
        #expect(codes.contains(.emptyPosition))
    }

    @Test func playerInTwoPlacesIsCaught() {
        // v1 blind spot #10: the empty-slot filler put the leadoff hitter in a second position.
        var lineup = validLineup(players)
        lineup.innings[0].positions[.rf] = lineup.innings[0].positions[.lf]
        let codes = Validator.validateDefense(lineup, context: context).map(\.code)
        #expect(codes.contains(.duplicatePlayer))
        #expect(codes.contains(.unaccountedPlayer))
    }

    @Test func wrongInningCountIsCaught() {
        var lineup = validLineup(players)
        lineup.innings.removeLast()
        #expect(Validator.validateDefense(lineup, context: context).map(\.code).contains(.wrongInningCount))
    }

    @Test func ineligiblePitcherIsCaught() {
        var lineup = validLineup(players)
        let nonPitcher = players[7].id
        lineup.innings[0].assign(nonPitcher, to: .field(.p))
        #expect(Validator.validateDefense(lineup, context: context).map(\.code).contains(.ineligiblePosition))
    }

    @Test func pitcherReentryIsCaught() {
        var lineup = validLineup(players)
        // Player 0 pitched innings 1–2; put them back on the mound in inning 5.
        lineup.innings[4].assign(players[0].id, to: .field(.p))
        let findings = Validator.validateDefense(lineup, context: context).filter { $0.code == .pitcherReentry }
        #expect(findings.count == 1)
        #expect(findings.first?.inning == 5)
    }

    @Test func brokenLockIsCaught() {
        let lineup = validLineup(players)
        var ctx = context
        ctx.locks = [Lock(inning: 1, player: players[9].id, slot: .field(.ss))]
        let slot = lineup.slot(of: players[9].id, inning: 1)
        try? #require(slot != .field(.ss))
        #expect(Validator.validateDefense(lineup, context: ctx).map(\.code).contains(.lockBroken))
    }

    @Test func unavailablePlayerIsCaughtAndLateArrivalIsRespected() {
        var ctx = context
        let late = players[10].id
        ctx.availability[late] = Availability(arrivesInning: 3)
        var lineup = validLineup(players)
        lineup.innings[0].assign(late, to: .field(.rf))
        let findings = Validator.validateDefense(lineup, context: ctx)
        #expect(findings.contains { $0.code == .unavailablePlayer && $0.inning == 1 })
    }

    @Test func battingOrderMustIncludeEveryoneOnce() {
        // v1 blind spot #6.
        var order = players.map(\.id)
        order.removeLast()
        order.append(order[0])
        let codes = Validator.validateBattingOrder(order, context: context).map(\.code)
        #expect(codes.contains(.battingMissingPlayer))
        #expect(codes.contains(.battingDuplicate))
    }

    @Test func absentPlayerCantBat() {
        var ctx = context
        ctx.availability[players[0].id] = .absent
        let codes = Validator.validateBattingOrder(players.map(\.id), context: ctx).map(\.code)
        #expect(codes.contains(.battingAbsentPlayer))
    }

    @Test func minFieldInningsRule() {
        var ctx = context
        ctx.rules = [TeamRule(text: "Everyone plays 5 innings", check: .minFieldInnings(5))]
        // 12 players × 6 innings with 9 fielders → 54 field innings, so some kids get only 4.
        let findings = Validator.validateDefense(validLineup(players), context: ctx)
        #expect(findings.contains { $0.code == .rule })
    }

    @Test func minFieldInningsScalesForPartialAttendance() {
        var ctx = context
        ctx.rules = [TeamRule(text: "Everyone plays 3 innings", check: .minFieldInnings(3))]
        let leaver = players[11].id
        ctx.availability[leaver] = Availability(leavesAfterInning: 2)
        var lineup = validLineup(players)
        for i in 2..<6 { lineup.innings[i].remove(leaver) }
        lineup.innings[0].assign(leaver, to: .field(.rf))
        lineup.innings[1].assign(leaver, to: .field(.rf))
        let ruleFindings = Validator.validateDefense(lineup, context: ctx).filter { $0.player == leaver && $0.code == .rule }
        #expect(ruleFindings.isEmpty)
    }

    @Test func consecutiveSitsRule() {
        var ctx = context
        ctx.rules = [TeamRule(text: "No sitting twice in a row", check: .maxConsecutiveSits(1))]
        var lineup = validLineup(players)
        let kid = players[11].id
        lineup.innings[0].assign(kid, to: .bench)
        lineup.innings[1].assign(kid, to: .bench)
        #expect(Validator.validateDefense(lineup, context: ctx).contains { $0.code == .rule && $0.player == kid })
    }

    @Test func feasibilityFlagsShortRosterBeforeAnyAICall() {
        var ctx = context
        for player in players.prefix(4) { ctx.availability[player.id] = .absent }
        #expect(Validator.feasibility(ctx).hasViolations)
    }

    @Test func feasibilityFlagsNoCatcherOnce() {
        var ctx = context
        ctx.availability[players[3].id] = .absent
        ctx.availability[players[4].id] = .absent
        let findings = Validator.feasibility(ctx)
        #expect(findings.count == 1)
        #expect(findings.first?.message == "Nobody can catch.")
    }

    @Test func feasibilityNamesInningsWhenOnlySomeAreShort() {
        var ctx = context
        ctx.availability[players[3].id] = Availability(leavesAfterInning: 4)
        ctx.availability[players[4].id] = .absent
        let findings = Validator.feasibility(ctx)
        #expect(findings.map(\.message) == ["Nobody can catch in innings 5, 6."])
    }

    @Test func swapMovesDisplacedPlayerToVacatedSlot() {
        // v1 blind spot #22: "swap" cleared the other player instead of swapping.
        var inning = validLineup(players).innings[0]
        let ss = inning.positions[.ss]!
        let lf = inning.positions[.lf]!
        inning.assign(lf, to: .field(.ss))
        #expect(inning.positions[.ss] == lf)
        #expect(inning.positions[.lf] == ss)
    }
}
