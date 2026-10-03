import Foundation
import Testing
@testable import LineupKit

private func hitter() -> PlayerSnapshot {
    var b = BattingLine()
    b.pa = 40; b.ab = 34; b.h = 12; b.singles = 9; b.doubles = 3; b.bb = 5; b.hbp = 1; b.so = 6; b.sb = 4; b.cs = 1
    var f = FieldingLine()
    f.tc = 20; f.po = 10; f.a = 8; f.e = 2; f.innings = [.ss: 12, .second: 6]
    var ratings = Ratings()
    ratings[.armStrength] = 4
    var profile = PositionProfile.default
    profile[.ss] = .primary
    return PlayerSnapshot(name: "Avery Test", jersey: "7", notes: "Great hustle\n\nNervous at the plate", profile: profile,
                          ratings: ratings, stats: PlayerStats(batting: b, fielding: f))
}

private let goodReply = """
{
  "summary": "Gets on base and anchors short.",
  "strengths": [ { "category": "On base", "description": "Walks and puts the ball in play", "evidence": ["obp", "bb_rate"] } ],
  "weaknesses": [ { "category": "Power", "description": "Mostly singles", "evidence": ["xbh"] } ],
  "batting": { "role": "table-setter", "zone": "Top of the order", "reason": "On-base skills" },
  "defense": [
    { "position": "2B", "fit": "solid", "reason": "Plays it", "evidence": ["inn.2b"] },
    { "position": "SS", "fit": "strong", "reason": "Arm and hands", "evidence": ["rating.fielding_arm_strength", "fpct"] }
  ],
  "eye_vs_data": null,
  "development_focus": [ { "focus": "Drive the ball", "drill": "Tee work" } ],
  "data_confidence": { "level": "medium", "reason": "40 PA" }
}
"""

@Suite struct FactSheetTests {
    @Test func playerFactsAreComputedAndUnknownsLeftOut() {
        let facts = FactSheet.player(hitter())
        #expect(facts["obp"]?.value == ".450")      // (12 + 5 + 1) / 40
        #expect(facts["k_rate"]?.value == "15%")
        #expect(facts["sb"]?.value == "4 of 5")
        #expect(facts["inn.ss"]?.value == "12")
        #expect(facts["rating.fielding_arm_strength"]?.value == "4/5")
        #expect(facts["rating.run_speed"] == nil)    // unrated stays unknown
        #expect(facts["p.ip"] == nil)
        #expect(facts["pos.ss"]?.value == "best")
        #expect(facts["pos.p"]?.value == "doesn't play")
        #expect(facts["note.1"]?.value == "Great hustle")
        #expect(facts["note.2"]?.value == "Nervous at the plate")
    }

    @Test func teamRatesComeFromCountsNotAverages() {
        var a = BattingLine(); a.pa = 10; a.ab = 10; a.h = 5
        var b = BattingLine(); b.pa = 30; b.ab = 30; b.h = 3
        let players = [a, b].map { PlayerSnapshot(name: "X", stats: PlayerStats(batting: $0)) }
        // (5 + 3) / 40 = .200; the average of .500 and .100 would be .300.
        #expect(FactSheet.team(players)["team.avg"]?.value == ".200")
    }

    @Test func fingerprintChangesWithInputs() {
        var player = hitter()
        let before = FactSheet.player(player).fingerprint
        #expect(before == FactSheet.player(player).fingerprint)
        player.ratings[.runSpeed] = 5
        #expect(before != FactSheet.player(player).fingerprint)
    }
}

@Suite struct ScoutTests {
    @Test func mapsAGroundedReply() async throws {
        let client = ScriptedClient([goodReply])
        let a = try await Scout(client: client, model: "m").assess(hitter(), ageGroup: "11U")
        #expect(client.requests.count == 1)
        #expect(client.requests[0].messages[0].content.contains("[obp] OBP: .450"))
        #expect(a.snapshot == "Gets on base and anchors short.")
        #expect(a.strengths.first?.evidence == ["obp", "bb_rate"])
        #expect(a.battingZone == .top)
        #expect(a.defense.map(\.position) == [.ss, .second])   // strongest first
        #expect(a.eyeVsData == nil)
        #expect(a.confidence == .medium)
        #expect(a.model == "m")
        #expect(a.cost == 0.01)
    }

    @Test func madeUpCitationGoesBackOnceThenIsDropped() async throws {
        let bad = goodReply.replacingOccurrences(of: "\"xbh\"", with: "\"hr_rate\"")
        let client = ScriptedClient([bad, bad])
        let a = try await Scout(client: client, model: "m").assess(hitter())
        #expect(client.requests.count == 2)
        #expect(client.requests[1].messages.last?.content.contains("[hr_rate]") == true)
        #expect(a.weaknesses.first?.evidence == [])
        #expect(a.cost == 0.02)
    }

    @Test func fixedCitationIsKept() async throws {
        let bad = goodReply.replacingOccurrences(of: "\"xbh\"", with: "\"hr_rate\"")
        let client = ScriptedClient([bad, goodReply])
        let a = try await Scout(client: client, model: "m").assess(hitter())
        #expect(a.weaknesses.first?.evidence == ["xbh"])
    }

    @Test func unreadableTwiceThrows() async {
        let client = ScriptedClient(["no json here", "still none"])
        await #expect(throws: ScoutError.self) { try await Scout(client: client, model: "m").assess(hitter()) }
    }

    @Test func teamAssessmentResolvesPlayersAndCitations() async throws {
        let players = [hitter(), PlayerSnapshot(name: "Blake Sample")]
        let reply = """
        {
          "team_strengths": [ { "category": "Discipline", "description": "P1 leads a patient lineup", "evidence": ["team.bb_rate", "P1.obp", "P9.obp"] } ],
          "team_weaknesses": [],
          "practice_recommendations": [ { "focus_area": "Catching", "drill_suggestions": "Blocking drills", "priority": "HIGH" } ],
          "lineup_insights": { "best_leadoff_candidates": ["P1", "P1", "P7"], "middle_of_order": ["P2"], "defensive_core": [], "defensive_concerns": ["Nobody catches"] },
          "summary": "Patient team."
        }
        """
        let client = ScriptedClient([reply, reply])
        let t = try await Scout(client: client, model: "m").assessTeam(players, assessments: [:])
        #expect(client.requests.count == 2)                       // P9.obp doesn't exist
        #expect(t.strengths.first?.evidence == ["team.bb_rate", "P1.obp"])
        #expect(t.strengths.first?.detail == "Avery leads a patient lineup")
        #expect(t.leadoff == [players[0].id])
        #expect(t.middleOrder == [players[1].id])
        #expect(t.practice.first?.priority == .high)
        #expect(t.facts["P1.obp"]?.label == "Avery OBP")
    }
}
