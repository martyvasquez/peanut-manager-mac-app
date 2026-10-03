#if DEBUG
import Foundation
import Synchronization
import SwiftData
import LineupKit

/// Debug-only launch flags for exercising the app without clicking or an API key:
///   -PMStore Name        use a separate library file (keeps your real library untouched)
///   -PMSeedSample YES    create the sample team on launch if there are no teams, and open its game
///   -PMFakeAI YES        use a scripted local "AI" instead of ChatGPT or OpenRouter
///   -PMAutoGenerate YES  make the batting order as soon as a game opens
///   -PMAutoPositions YES then set positions automatically
///   -PMOpenPicker YES    open the position picker on the third batter, inning 1
///   -PMScrollToChecks YES scroll to the game plan and checks once a lineup exists
///   -PMAssessTeam YES    assess the team as soon as Insights opens
///   -PMFlakyScout YES    fake Scout: Player03 times out once, Player05 always times out
enum DebugSupport {
    static var seedSample: Bool { UserDefaults.standard.bool(forKey: "PMSeedSample") }
    static var fakeAI: Bool { UserDefaults.standard.bool(forKey: "PMFakeAI") }
    static var autoGenerate: Bool { UserDefaults.standard.bool(forKey: "PMAutoGenerate") }
    static var autoPositions: Bool { UserDefaults.standard.bool(forKey: "PMAutoPositions") }
    static var scrollToChecks: Bool { UserDefaults.standard.bool(forKey: "PMScrollToChecks") }
    static var assessTeam: Bool { UserDefaults.standard.bool(forKey: "PMAssessTeam") }
    nonisolated static var flakyScout: Bool { UserDefaults.standard.bool(forKey: "PMFlakyScout") }

    @MainActor
    static func seedIfRequested(teams: [Team], context: ModelContext) -> Team? {
        guard seedSample, teams.isEmpty else { return nil }
        return try? SampleData.makeTeam(in: context)
    }
}

/// Answers like a model would. Its first defense deliberately puts one player in two places in inning 2,
/// so the validator → revise path is visible; the revision is correct.
struct FakeLLMClient: LLMClient {
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await Task.sleep(for: .milliseconds(900))
        let prompt = request.messages.first?.content ?? ""
        if request.system.contains("player analyst") {
            if DebugSupport.flakyScout {
                // Player03 times out once, then answers; Player05 always times out.
                let name = prompt.firstMatch(of: /PLAYER: ([^\n]+)/).map { String($0.1) } ?? ""
                try await Task.sleep(for: .seconds(3))
                let attempt = Self.attempts.withLock { counts in counts[name, default: 0] += 1; return counts[name]! }
                if name.contains("Player05") || (name.contains("Player03") && attempt == 1) { throw URLError(.timedOut) }
            }
            return Self.scoutPlayer(prompt)
        }
        if request.system.contains("team analyst") { return Self.scoutTeam(prompt) }
        let ids = Self.ids(in: prompt)
        let isRevision = request.messages.count > 1
        if prompt.contains("coming up with the batting order") {
            let entries = ids.enumerated().map { "{\"order\": \($0.offset + 1), \"player_id\": \"\($0.element)\", \"reasoning\": \"Scripted reasoning for slot \($0.offset + 1).\"}" }
            return LLMResponse(text: "{\"batting_order\": [\(entries.joined(separator: ","))], \"rationale\": \"Best on-base hitters up top, power in the 3–5 spots, developing hitters at the bottom.\"}", usage: LLMUsage(promptTokens: 1500, completionTokens: 400, cost: 0.006))
        }
        let innings = Int(prompt.firstMatch(of: /positions for (\d+) innings/)?.1 ?? "6") ?? 6
        let pitchers = Self.ids(withEligibility: "Pitch: yes", in: prompt)
        let catchers = Self.ids(withEligibility: "Catch: yes", in: prompt)
        var rows: [String] = []
        for inning in 0..<innings {
            let p = pitchers.isEmpty ? ids[0] : pitchers[min(inning / 2, pitchers.count - 1)]
            let c = catchers.first { $0 != p } ?? ids.first { $0 != p }!
            var rest = ids.filter { $0 != p && $0 != c }
            let shift = (inning * 3) % max(rest.count, 1)
            rest = Array(rest[shift...] + rest[..<shift])
            let positions = ["1B", "2B", "3B", "SS", "LF", "CF", "RF"]
            var fields = ["\"inning\": \(inning + 1)", "\"P\": \"\(p)\"", "\"C\": \"\(c)\""]
            for (index, position) in positions.enumerated() where index < rest.count {
                // First answer: inning 2 RF duplicates LF.
                let id = (!isRevision && inning == 1 && position == "RF") ? rest[4] : rest[index]
                fields.append("\"\(position)\": \"\(id)\"")
            }
            let sitting = rest.dropFirst(positions.count).map { "\"\($0)\"" }
            fields.append("\"sit\": [\(sitting.joined(separator: ","))]")
            fields.append("\"reasoning\": \"Inning \(inning + 1): rotate the outfield and keep the strongest arm on the mound.\"")
            rows.append("{" + fields.joined(separator: ", ") + "}")
        }
        let text = "{\"defense\": [\(rows.joined(separator: ","))], \"rules_check\": [{\"rule\": \"All players must be included in the batting order.\", \"satisfied\": true, \"details\": \"Everyone bats.\"}], \"warnings\": [], \"rationale\": \"Strong defense up the middle early, pitchers limited to two innings, and every player gets infield time by the 4th.\"}"
        return LLMResponse(text: text, usage: LLMUsage(promptTokens: 3000, completionTokens: 1200, cost: 0.02))
    }

    static let attempts = Mutex<[String: Int]>([:])

    /// A plausible player assessment built from whatever facts the prompt lists.
    static func scoutPlayer(_ prompt: String) -> LLMResponse {
        var facts: [String: String] = [:]
        for match in prompt.matches(of: /\n\[([a-z0-9_.]+)\] [^:\n]+: ([^\n]+)/) { facts[String(match.1)] = String(match.2) }
        let obp = Double(facts["obp"].map { "0" + $0 } ?? "") ?? 0
        let slg = Double(facts["slg"].map { "0" + $0 } ?? "") ?? 0
        let (role, zone, summary) =
            obp >= 0.42 ? ("table-setter", "top", "Gets on base at a high rate and makes the pitcher work. A natural leadoff bat.")
            : slg >= 0.40 ? ("gap power", "middle", "Drives the ball when he gets a pitch to hit. Belongs in the middle of the order.")
            : ("developing", "bottom", "Still finding his timing at the plate, but competes every at-bat and is improving in the field.")
        let cite = { (ids: [String]) in "[" + ids.filter { facts[$0] != nil }.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
        let positions = ["p", "c", "1b", "2b", "3b", "ss", "lf", "cf", "rf"].filter { facts["pos.\($0)"] == "best" || facts["pos.\($0)"] == "good" }
        let others = ["ss", "2b", "cf", "3b", "lf", "rf", "1b"].filter { facts["pos.\($0)"] == "plays" }.prefix(max(0, 3 - positions.count))
        let defense = (positions.map { ($0, "strong", "Coach's best spot for him, and the fielding numbers back it up") }
                       + others.map { ($0, "solid", "Reliable here; makes the routine plays") })
            .map { "{\"position\": \"\($0.0.uppercased())\", \"fit\": \"\($0.1)\", \"reason\": \"\($0.2)\", \"evidence\": \(cite(["fpct", "inn.\($0.0)", "rating.fielding_hands"]))}" }
        let text = """
        {"summary": "\(summary)",
         "strengths": [
           {"category": "On base", "description": "Patient at the plate and rarely gives away an at-bat", "evidence": \(cite(["obp", "bb_rate", "rating.plate_discipline"]))},
           {"category": "Hands", "description": "Sure hands on routine chances", "evidence": \(cite(["fpct", "rating.fielding_hands"]))}
         ],
         "weaknesses": [
           {"category": "Strikeouts", "description": "Chases with two strikes", "evidence": \(cite(["k_rate"]))}
         ],
         "batting": {"role": "\(role)", "zone": "\(zone)", "reason": "Fits how he gets on base"},
         "defense": [\(defense.joined(separator: ","))],
         "eye_vs_data": \(facts["rating.contact_ability"] != nil && facts["avg"] != nil ? "\"Your contact rating is higher than his average so far. With this few plate appearances, trust your eye a little longer.\"" : "null"),
         "development_focus": [{"focus": "Two-strike approach", "drill": "Choke up and battle: two-strike soft toss"}],
         "data_confidence": {"level": "\(Int(facts["pa"] ?? "0") ?? 0 >= 30 ? "high" : "medium")", "reason": "A full season of plate appearances and most skills rated."}
        }
        """
        return LLMResponse(text: text, usage: LLMUsage(promptTokens: 1200, completionTokens: 500, cost: 0.008))
    }

    static func scoutTeam(_ prompt: String) -> LLMResponse {
        let ids = prompt.matches(of: #/\n(P\d+): /#).map { String($0.1) }
        func pick(_ range: Range<Int>) -> String { "[" + ids.indices.filter(range.contains).map { "\"\(ids[$0])\"" }.joined(separator: ", ") + "]" }
        let text = """
        {"team_strengths": [
           {"category": "Plate discipline", "description": "A patient lineup that draws walks and works counts", "evidence": ["team.bb_rate", "team.obp"]},
           {"category": "Speed", "description": "Puts pressure on the defense once on base", "evidence": ["team.sb"]}
         ],
         "team_weaknesses": [
           {"category": "Strikeouts", "description": "Too many at-bats end without the ball in play, especially at the bottom of the order", "evidence": ["team.k_rate"]},
           {"category": "Catching depth", "description": "Only a couple of players can catch", "evidence": ["team.catchers"]}
         ],
         "practice_recommendations": [
           {"focus_area": "Two-strike hitting", "drill_suggestions": "Two-strike soft toss and short-bat drills; reward balls in play", "priority": "high"},
           {"focus_area": "Catching", "drill_suggestions": "Blocking and receiving for two more players each practice", "priority": "medium"},
           {"focus_area": "Base running", "drill_suggestions": "Secondary leads and reading the ball in the dirt", "priority": "low"}
         ],
         "lineup_insights": {"best_leadoff_candidates": \(pick(0..<2)), "middle_of_order": \(pick(2..<5)), "defensive_core": \(pick(5..<8)), "defensive_concerns": ["Catching depth if \(ids.first ?? "P1") is out"]},
         "summary": "A patient, aggressive team on the bases whose biggest gap is putting the ball in play. Two-strike hitting and catching depth are the priorities."
        }
        """
        return LLMResponse(text: text, usage: LLMUsage(promptTokens: 6000, completionTokens: 700, cost: 0.03))
    }

    static func ids(in prompt: String) -> [String] {
        var seen = Set<String>()
        return prompt.matches(of: /\nID: (P\d+)/).map { String($0.1) }.filter { seen.insert($0).inserted }
    }

    static func ids(withEligibility marker: String, in prompt: String) -> [String] {
        prompt.components(separatedBy: "\n---\n").compactMap { block in
            guard block.contains(marker), let match = block.firstMatch(of: /ID: (P\d+)/) else { return nil }
            return String(match.1)
        }
    }
}
#endif
