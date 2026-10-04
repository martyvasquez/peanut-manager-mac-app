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
