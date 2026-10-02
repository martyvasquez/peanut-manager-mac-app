import Foundation
import Testing
@testable import LineupKit

struct RepairTests {
    let players = makeTeam()

    /// Invariant violations (not coach rules) that the safety net must always clear on a feasible game.
    func invariantViolations(_ lineup: Lineup, _ context: GameContext) -> [Finding] {
        Validator.validateDefense(lineup, context: context).violations.filter { $0.code != .rule }
    }

    @Test func leavesValidLineupUntouched() {
        let context = GameContext(innings: 6, players: players)
        let result = Repair.defense(validLineup(players), context: context)
        #expect(result.adjusted.isEmpty)
        #expect(result.lineup == validLineup(players))
    }

    @Test func fixesDuplicateWithMinimalChanges() {
        let context = GameContext(innings: 6, players: players)
        var broken = validLineup(players)
        broken.innings[0].positions[.rf] = broken.innings[0].positions[.lf]
        let result = Repair.defense(broken, context: context)
        #expect(invariantViolations(result.lineup, context).isEmpty)
        #expect(result.adjusted.allSatisfy { $0.inning == 1 })
        #expect(result.adjusted.count <= 2)
    }

    @Test func respectsLocksAndEligibilityWhenFixingPitcherReentry() {
        // v1 blind spot #11: the re-entry swap ignored eligibility and locks.
        var context = GameContext(innings: 6, players: players)
        var broken = validLineup(players)
        broken.innings[4].assign(players[0].id, to: .field(.p))
        let lockedFielder = broken.innings[4].positions[.ss]!
        context.locks = [Lock(inning: 5, player: lockedFielder, slot: .field(.ss))]
        let result = Repair.defense(broken, context: context)
        #expect(invariantViolations(result.lineup, context).isEmpty)
        let pitcher = result.lineup.innings[4].positions[.p]!
        #expect(pitcher != players[0].id)
        #expect(context.player(pitcher)!.profile.canPlay(.p))
        #expect(result.lineup.innings[4].positions[.ss] == lockedFielder)
    }

    @Test func randomlyBrokenLineupsAlwaysComeBackValid() {
        var rng = SeededRNG(seed: 42)
        for _ in 0..<300 {
            var context = GameContext(innings: 6, players: players)
            if Bool.random(using: &rng) { context.availability[players[11].id] = Availability(arrivesInning: Int.random(in: 2...4, using: &rng)) }
            var lineup = validLineup(players)
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let inning = Int.random(in: 0..<6, using: &rng)
                let position = Position.allCases.randomElement(using: &rng)!
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: lineup.innings[inning].positions[position] = nil
                case 1: lineup.innings[inning].positions[position] = players.randomElement(using: &rng)!.id
                case 2: lineup.innings[inning].positions[position] = UUID()
                default: lineup.innings[inning].sitting.removeAll()
                }
            }
            if Bool.random(using: &rng) { lineup.innings.removeLast() }
            let lockPlayer = players[Int.random(in: 5..<10, using: &rng)].id
            context.locks = [Lock(inning: 3, player: lockPlayer, slot: .field(.cf))]

            let result = Repair.defense(lineup, context: context)
            #expect(invariantViolations(result.lineup, context).isEmpty)
            #expect(result.lineup.innings[2].positions[.cf] == lockPlayer)
        }
    }

    @Test func battingRepairAppendsMissingAndDropsBadEntries() {
        var context = GameContext(innings: 6, players: players)
        context.availability[players[5].id] = .absent
        let order = [players[0].id, players[0].id, UUID(), players[5].id, players[1].id]
        let repaired = Repair.battingOrder(order, context: context)
        #expect(Array(repaired.prefix(2)) == [players[0].id, players[1].id])
        #expect(Validator.validateBattingOrder(repaired, context: context).isEmpty)
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
