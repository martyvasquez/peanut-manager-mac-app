import Testing
@testable import LineupKit

/// Direct edits on the positions grid: swapping two kids, and adding, removing or moving innings.
struct GridEditTests {
    let players = makeTeam()
    var ids: [PlayerID] { players.map(\.id) }

    @Test func swapTradesTwoPositions() {
        var inning = validLineup(players).innings[0]
        let a = inning.positions[.p]!, b = inning.positions[.ss]!
        inning.swap(a, b)
        #expect(inning.positions[.p] == b && inning.positions[.ss] == a)
    }

    @Test func swapWithTheBenchPutsTheSitterInTheField() {
        var inning = validLineup(players).innings[0]
        let fielder = inning.positions[.cf]!, sitter = inning.sitting[0]
        inning.swap(fielder, sitter)
        #expect(inning.positions[.cf] == sitter)
        #expect(inning.sitting.contains(fielder) && !inning.sitting.contains(sitter))
    }

    @Test func swapWithSomeoneUnplacedMovesThemIn() {
        var inning = InningAssignment(positions: [.p: ids[0]])
        inning.swap(ids[0], ids[1])
        #expect(inning.positions[.p] == ids[1])
        #expect(inning.slot(of: ids[0]) == nil)
    }

    @Test func insertShiftsLaterInnings() {
        var lineup = validLineup(players)
        let third = lineup.innings[2]
        let map = lineup.insertInning(at: 3)
        #expect(lineup.innings.count == 7)
        #expect(lineup.innings[2] == InningAssignment())
        #expect(lineup.innings[3] == third)
        #expect(map(2) == 2 && map(3) == 4 && map(6) == 7)
    }

    @Test func removeDropsTheInningAndShiftsDown() {
        var lineup = validLineup(players)
        let fourth = lineup.innings[3]
        let map = lineup.removeInning(3)
        #expect(lineup.innings.count == 5)
        #expect(lineup.innings[2] == fourth)
        #expect(map(3) == nil && map(4) == 3 && map(2) == 2)
    }

    @Test func moveCarriesTheInningAndShiftsTheOnesBetween() {
        var lineup = validLineup(players)
        let original = lineup.innings
        let map = lineup.moveInning(4, to: 1)
        #expect(lineup.innings == [original[3], original[0], original[1], original[2], original[4], original[5]])
        #expect(map(4) == 1 && map(1) == 2 && map(3) == 4 && map(5) == 5)

        var back = validLineup(players)
        let down = back.moveInning(1, to: 4)
        #expect(back.innings == [original[1], original[2], original[3], original[0], original[4], original[5]])
        #expect(down(1) == 4 && down(2) == 1 && down(4) == 3 && down(6) == 6)
    }
}
