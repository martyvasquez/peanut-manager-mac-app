import Testing
@testable import LineupKit

/// Building a batting order by hand: drop a kid in any spot, gaps and all.
struct BattingSlotsTests {
    let ids = makeTeam(5).map(\.id)

    @Test func dropsIntoAnyEmptySpot() {
        let slots = BattingSlots.place(ids[0], at: 3, in: Array(repeating: nil, count: 5))
        #expect(slots == [nil, nil, nil, ids[0], nil])
    }

    @Test func noSpotGivenFillsTheFirstEmptyOne() {
        let slots = BattingSlots.place(ids[1], at: nil, in: [ids[0], nil, nil, ids[2], nil])
        #expect(slots == [ids[0], ids[1], nil, ids[2], nil])
    }

    @Test func aTakenSpotShiftsKidsTowardTheNearestGapBelow() {
        let slots = BattingSlots.place(ids[3], at: 0, in: [ids[0], ids[1], nil, ids[2], nil])
        #expect(slots == [ids[3], ids[0], ids[1], ids[2], nil])
    }

    @Test func withNoGapBelowKidsShiftUp() {
        let slots = BattingSlots.place(ids[3], at: 4, in: [nil, ids[0], ids[1], ids[2], ids[4]])
        #expect(slots == [ids[0], ids[1], ids[2], ids[4], ids[3]])
    }

    @Test func movingWithinAFullOrderIsAnInsert() {
        let full: [PlayerID?] = ids
        #expect(BattingSlots.place(ids[4], at: 1, in: full) == [ids[0], ids[4], ids[1], ids[2], ids[3]])
        #expect(BattingSlots.place(ids[0], at: 3, in: full) == [ids[1], ids[2], ids[3], ids[0], ids[4]])
    }

    @Test func savedSpotsSurviveWhileTheyMatchTheOrder() {
        let saved: [PlayerID?] = [nil, ids[0], nil, ids[1], nil]
        #expect(BattingSlots.resolve(saved, order: [ids[0], ids[1]], present: ids) == saved)
    }

    @Test func aChangedOrderStartsFromTheTop() {
        let saved: [PlayerID?] = [nil, ids[0], nil, ids[1], nil]
        #expect(BattingSlots.resolve(saved, order: [ids[1], ids[0]], present: ids) == [ids[1], ids[0], nil, nil, nil])
    }

    @Test func aKidWhoIsntHereLeavesAGapAndTheSpotsFitWhoIs() {
        let saved: [PlayerID?] = [ids[0], ids[1], nil, nil, ids[4]]
        let here = Array(ids.prefix(4))
        #expect(BattingSlots.resolve(saved, order: [ids[0], ids[1], ids[4]], present: here) == [ids[0], ids[1], nil, nil])
    }
}
