import Foundation
import Testing
@testable import LineupKit

private func hitter(pa: Int, onBase: Int, so: Int = 0) -> (id: PlayerID, stats: PlayerStats?) {
    var b = BattingLine()
    b.pa = pa; b.ab = pa; b.h = onBase; b.singles = onBase; b.so = so
    return (UUID(), PlayerStats(batting: b))
}

@Test func ranksBestFirstWithTies() {
    let a = hitter(pa: 40, onBase: 20), b = hitter(pa: 40, onBase: 16), c = hitter(pa: 40, onBase: 16), d = hitter(pa: 40, onBase: 8)
    let ranks = TeamRanks([a, b, c, d])
    #expect(ranks.standing(a.id, .obp)?.rankText == "1st")
    #expect(ranks.standing(b.id, .obp)?.rankText == "T-2nd")
    #expect(ranks.standing(c.id, .obp)?.rankText == "T-2nd")
    #expect(ranks.standing(d.id, .obp)?.rankText == "4th")
    #expect(ranks.leaders(.obp).count == 3)
}

@Test func lowerIsBetterForStrikeouts() {
    let a = hitter(pa: 40, onBase: 10, so: 2), b = hitter(pa: 40, onBase: 10, so: 12)
    let ranks = TeamRanks([a, b])
    #expect(ranks.standing(a.id, .kRate)?.rank == 1)
    #expect(ranks.standing(b.id, .kRate)?.rank == 2)
}

@Test func smallSamplesAreShownButNotRanked() {
    let regular = hitter(pa: 50, onBase: 20), hot = hitter(pa: 12, onBase: 11), tiny = hitter(pa: 4, onBase: 4)
    let ranks = TeamRanks([regular, hot, tiny])
    // 12 PA is under 40% of 50; 4 PA is under the 10-PA floor.
    #expect(ranks.standing(hot.id, .obp)?.rank == nil)
    #expect(ranks.standing(tiny.id, .obp)?.rank == nil)
    #expect(ranks.standing(hot.id, .obp)?.value == 11.0 / 12.0)
    #expect(ranks.standing(regular.id, .obp)?.rankText == "1st")
    #expect(ranks.standing(regular.id, .obp)?.of == 1)
}

@Test func playersWithoutStatsAreLeftOut() {
    let a = hitter(pa: 40, onBase: 20)
    let ranks = TeamRanks([a, (UUID(), nil)])
    #expect(ranks.ranked(.obp).count == 1)
    #expect(ranks.ranked(.era).isEmpty)
}

@Test func ordinals() {
    #expect([1, 2, 3, 4, 11, 12, 13, 21, 22].map(Standing.ordinal) == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd"])
}

@Test func factSides() {
    #expect(Side.of("obp") == .offense)
    #expect(Side.of("team.k_rate") == .offense)
    #expect(Side.of("P3.slg") == .offense)
    #expect(Side.of("inn.ss") == .defense)
    #expect(Side.of("team.p.whip") == .defense)
    #expect(Side.of("P12.c.pb") == .defense)
    #expect(Side.of("rating.fielding_arm_strength") == .defense)
    #expect(Side.of("note.2") == nil)
    #expect(Side.of("rating.baseball_iq") == nil)
    #expect(Claim(title: "", detail: "", evidence: ["obp", "bb_rate", "fpct"]).side == .offense)
    #expect(Claim(title: "", detail: "", evidence: ["obp", "fpct"]).side == nil)
    #expect(Claim(title: "", detail: "", evidence: ["note.1"]).side == nil)
}

@Test func twoWayDefense() {
    var r = Ratings()
    #expect(TwoWay.defense(ratings: r, bestFit: .strong) == nil)
    r[.fieldingHands] = 4; r[.armStrength] = 3
    #expect(TwoWay.defense(ratings: r, bestFit: nil) == 3.5)
    #expect(TwoWay.defense(ratings: r, bestFit: .strong) == 4.0)
    #expect(TwoWay.defense(ratings: r, bestFit: .developing) == 3.0)
    r[.fieldingHands] = 5; r[.armStrength] = 5
    #expect(TwoWay.defense(ratings: r, bestFit: .strong) == 5)
    r[.pitchVelocity] = 1  // not a fielding rating
    #expect(TwoWay.defense(ratings: r, bestFit: .solid) == 5)
}
