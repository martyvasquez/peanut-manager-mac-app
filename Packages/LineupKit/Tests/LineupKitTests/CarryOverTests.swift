import Testing
@testable import LineupKit

/// Copying a previous game's lineup as the start of a new one.
struct CarryOverTests {
    let players = makeTeam()
    var ids: [PlayerID] { players.map(\.id) }

    @Test func everyoneComingKeepsTheSameLineup() {
        let last = validLineup(players)
        let copy = last.carriedOver(innings: 6, present: Set(ids), available: { _ in ids })
        #expect(copy == last)
        #expect(copy.isFullyPositioned)
    }

    @Test func aMissingKidLeavesTheirSpotsOpen() {
        let last = validLineup(players)
        let gone = ids[5]
        let here = ids.filter { $0 != gone }
        let copy = last.carriedOver(innings: 6, present: Set(here), available: { _ in here })
        #expect(!copy.battingOrder.contains(gone))
        for (index, inning) in copy.innings.enumerated() {
            #expect(inning.slot(of: gone) == nil)
            let wasFielding = last.innings[index].positions.values.contains(gone)
            #expect(inning.openPositions.count == (wasFielding ? 1 : 0))
        }
        #expect(!copy.isFullyPositioned)
    }

    @Test func extraInningsAreCutAndMissingOnesStartEmpty() {
        let last = validLineup(players, innings: 6)
        #expect(last.carriedOver(innings: 4, present: Set(ids), available: { _ in ids }).innings.count == 4)
        let longer = last.carriedOver(innings: 7, present: Set(ids), available: { _ in ids })
        #expect(longer.innings.count == 7)
        #expect(longer.innings[6] == InningAssignment())
    }

    @Test func aNewKidSitsInFullInnings() {
        let last = validLineup(Array(players.prefix(11)))
        let copy = last.carriedOver(innings: 6, present: Set(ids), available: { _ in ids })
        #expect(copy.innings.allSatisfy { $0.sitting.contains(ids[11]) })
        #expect(!copy.battingOrder.contains(ids[11]))
    }

    @Test func battingOrderOnlyCopiesNoGrid() {
        let last = Lineup(battingOrder: ids)
        #expect(last.carriedOver(innings: 6, present: Set(ids), available: { _ in ids }).innings.isEmpty)
    }
}
