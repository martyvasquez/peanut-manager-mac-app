import Foundation
import Testing
@testable import LineupKit

struct GameChangerImportTests {
    func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "gc-season", withExtension: "csv", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func parsesEveryPlayerAndSkipsTotalsAndGlossary() throws {
        let rows = try GameChangerImport.parse(fixture())
        #expect(rows.count == 12)
        #expect(!rows.contains { $0.number == "Totals" })
        #expect(rows[1].number == "6")
        #expect(rows[1].fullName == "Blake Player02")
    }

    @Test func readsColumnsFromTheirOwnSection() throws {
        let rows = try GameChangerImport.parse(fixture())
        let blake = rows[1]
        // Batting: 14 PA, 9 AB, AVG .222 → 2 hits.
        #expect(blake.batting.pa == 14)
        #expect(blake.batting.ab == 9)
        #expect(blake.batting.h == 2)
        // Pitching IP "3.1" = 10 outs. Pitching H/BB/SO must not be confused with batting H/BB/SO.
        #expect(blake.pitching.outs == 10)
        #expect(blake.fielding.tc == 3)
    }

    @Test func computesRatesInCode() throws {
        let rows = try GameChangerImport.parse(fixture())
        let lane = try #require(rows.first { $0.number == "99" })
        #expect(lane.fielding.tc == 43)
        let fpct = try #require(lane.fielding.fpct)
        #expect(fpct > 0 && fpct <= 1)
        let avg = try #require(lane.batting.avg)
        #expect(abs(avg - 0.267) < 0.001)
    }

    @Test func rejectsNonGameChangerCSV() {
        #expect(throws: GameChangerImportError.notGameChangerExport) {
            try GameChangerImport.parse("Name,Score\nA,1\n")
        }
    }

    @Test func matchesByJerseyThenExactNameOnly() throws {
        let rows = try GameChangerImport.parse(fixture())
        let roster = [
            PlayerSnapshot(name: "Blake Player02", jersey: "6"),
            PlayerSnapshot(name: "Casey Player03"),
            PlayerSnapshot(name: "Drew Smith"),
        ]
        #expect(GameChangerImport.match(rows[1], roster: roster) == .jersey(roster[0].id))
        #expect(GameChangerImport.match(rows[2], roster: roster) == .name(roster[1].id))
        // v1 matched on "last name contains"; v2 refuses to guess.
        #expect(GameChangerImport.match(rows[3], roster: roster) == .none)
    }

    @Test func ipConversion() {
        #expect(PitchingLine.outs(fromIP: "12.1") == 37)
        #expect(PitchingLine.outs(fromIP: "0.0") == 0)
        #expect(PitchingLine.outs(fromIP: "4.3") == nil)
    }

    @Test func csvHandlesQuotesAndCommas() {
        let rows = CSV.parse("\"a, b\",\"say \"\"hi\"\"\",c\r\n1,2,3")
        #expect(rows == [["a, b", "say \"hi\"", "c"], ["1", "2", "3"]])
    }
}
