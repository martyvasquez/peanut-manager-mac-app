import Foundation
@testable import LineupKit

/// A 12-player team. Players 0–2 can pitch, 3–4 can catch, everyone else can't do either.
func makeTeam(_ count: Int = 12) -> [PlayerSnapshot] {
    (0..<count).map { i in
        var profile = PositionProfile.default
        if i < 3 { profile[.p] = .good }
        if i == 3 || i == 4 { profile[.c] = .primary }
        return PlayerSnapshot(name: "Player \(i + 1)", jersey: "\(i + 1)", profile: profile)
    }
}

/// A valid rotation: P/C/IF/OF filled legally each inning, the rest sit.
func validLineup(_ players: [PlayerSnapshot], innings: Int = 6) -> Lineup {
    let ids = players.map(\.id)
    let fielders: [Position] = [.first, .second, .third, .ss, .lf, .cf, .rf]
    var result: [InningAssignment] = []
    for inning in 0..<innings {
        var a = InningAssignment()
        // Pitchers: player 0 for innings 1–2, player 1 for 3–4, player 2 for 5–6 (no re-entry).
        a.positions[.p] = ids[min(inning / 2, 2)]
        a.positions[.c] = ids[3 + (inning % 2)]
        let others = ids.enumerated().filter { $0.element != a.positions[.p] && $0.element != a.positions[.c] }.map(\.element)
        let rotated = Array(others[(inning % others.count)...] + others[..<(inning % others.count)])
        for (position, id) in zip(fielders, rotated) { a.positions[position] = id }
        a.sitting = Array(rotated.dropFirst(fielders.count))
        result.append(a)
    }
    return Lineup(battingOrder: ids, innings: result)
}

/// Replays canned model replies in order.
final class ScriptedClient: LLMClient, @unchecked Sendable {
    private var replies: [String]
    private(set) var requests: [LLMRequest] = []
    private let lock = NSLock()

    init(_ replies: [String]) { self.replies = replies }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let next: String? = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let next else { throw URLError(.badServerResponse) }
        return LLMResponse(text: next, usage: LLMUsage(promptTokens: 100, completionTokens: 50, cost: 0.01))
    }
}

/// Renders a lineup as the model's JSON reply (short IDs).
func defenseJSON(_ lineup: Lineup, players: [PlayerSnapshot]) -> String {
    let ids = PromptIDs(players: players)
    let innings = lineup.innings.enumerated().map { index, inning -> String in
        var fields = ["\"inning\": \(index + 1)"]
        for position in Position.allCases {
            if let id = inning.positions[position] { fields.append("\"\(position.rawValue)\": \"\(ids.token(id))\"") }
        }
        fields.append("\"sit\": [" + inning.sitting.map { "\"\(ids.token($0))\"" }.joined(separator: ",") + "]")
        fields.append("\"reasoning\": \"inning \(index + 1)\"")
        return "{" + fields.joined(separator: ", ") + "}"
    }
    return "{\"defense\": [\(innings.joined(separator: ","))], \"rules_check\": [], \"warnings\": [], \"rationale\": \"ok\"}"
}

func battingJSON(_ order: [PlayerID], players: [PlayerSnapshot]) -> String {
    let ids = PromptIDs(players: players)
    let entries = order.enumerated().map { "{\"order\": \($0.offset + 1), \"player_id\": \"\(ids.token($0.element))\", \"reasoning\": \"why\"}" }
    return "```json\n{\"batting_order\": [\(entries.joined(separator: ","))], \"rationale\": \"top-heavy\"}\n```"
}
