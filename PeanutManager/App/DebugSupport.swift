#if DEBUG
import Foundation
import SwiftData
import LineupKit

/// Debug-only launch flags for exercising the app without clicking or an API key:
///   -PMStore Name        use a separate library file (keeps your real library untouched)
///   -PMSeedSample YES    create the sample team on launch if there are no teams, and open its game
///   -PMFakeAI YES        use a scripted local "AI" instead of OpenRouter
///   -PMAutoGenerate YES  start generating as soon as a game opens
///   -PMScrollToChecks YES scroll to the game plan and checks once a lineup exists
enum DebugSupport {
    static var seedSample: Bool { UserDefaults.standard.bool(forKey: "PMSeedSample") }
    static var fakeAI: Bool { UserDefaults.standard.bool(forKey: "PMFakeAI") }
    static var autoGenerate: Bool { UserDefaults.standard.bool(forKey: "PMAutoGenerate") }
    static var scrollToChecks: Bool { UserDefaults.standard.bool(forKey: "PMScrollToChecks") }

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
