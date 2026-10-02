import Foundation

/// Raw AI output for phase 1.
struct BattingOrderResponse: Decodable {
    struct Entry: Decodable {
        var order: Int?
        var player_id: PlayerRef
        var reasoning: String?
    }
    var batting_order: [Entry]
    var rationale: String?
}

/// Raw AI output for phase 2.
struct DefenseResponse: Decodable {
    struct Inning: Decodable {
        var inning: Int?
        var positions: [Position: PlayerRef]
        var sit: [PlayerRef]
        var reasoning: String?

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            inning = try? container.decode(Int.self, forKey: Key(stringValue: "inning"))
            reasoning = try? container.decode(String.self, forKey: Key(stringValue: "reasoning"))
            sit = (try? container.decode([PlayerRef].self, forKey: Key(stringValue: "sit"))) ?? []
            positions = [:]
            for key in container.allKeys {
                guard let position = Position(label: key.stringValue),
                      let ref = try? container.decode(PlayerRef.self, forKey: key) else { continue }
                positions[position] = ref
            }
        }
    }

    struct RuleCheck: Decodable {
        var rule: String
        var satisfied: Bool?
        var details: String?
    }

    var defense: [Inning]
    var rules_check: [RuleCheck]?
    var warnings: [String]?
    var rationale: String?
}

/// A player reference as models actually write it: "P3", or v1-style {"id": "P3", "name": "Ava"}, or null.
struct PlayerRef: Decodable {
    var id: String?
    var name: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if let string = try? container.decode(String.self) {
            id = string
            return
        }
        struct Object: Decodable { var id: String?; var player_id: String?; var name: String? }
        let object = try container.decode(Object.self)
        id = object.id ?? object.player_id
        name = object.name
    }

    /// Resolves to a roster player. Falls back to an exact, unique name match (v1 did this too).
    func resolve(ids: PromptIDs, players: [PlayerSnapshot]) -> PlayerID? {
        if let id = id?.trimmingCharacters(in: .whitespaces) {
            if let player = ids.byToken[id.uppercased()] { return player }
            if let uuid = UUID(uuidString: id), players.contains(where: { $0.id == uuid }) { return uuid }
        }
        let candidates = [name, id].compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
        for candidate in candidates {
            let matches = players.filter { $0.name.lowercased() == candidate }
            if matches.count == 1 { return matches[0].id }
        }
        return nil
    }
}

public enum AIResponseError: Error, LocalizedError {
    case noJSON(String)
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case .noJSON: "The AI didn't return a lineup."
        case .undecodable(let detail): "The AI's response wasn't in the expected format (\(detail))."
        }
    }
}

enum JSONExtraction {
    /// Pulls the outermost JSON object out of a model reply (tolerates code fences and stray prose).
    static func object(in text: String) throws -> Data {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw AIResponseError.noJSON(text)
        }
        return Data(text[start...end].utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = try object(in: text)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIResponseError.undecodable(String(describing: error))
        }
    }
}

/// The AI's batting order mapped onto roster IDs. Unresolvable entries are kept as `nil` slots
/// so the validator reports them instead of them silently vanishing.
struct MappedBattingOrder {
    var order: [PlayerID]
    var reasons: [PlayerID: String]
    var unresolved: Int
    var rationale: String
}

struct MappedDefense {
    var innings: [InningAssignment]
    var inningReasons: [String]
    var unresolved: [(inning: Int, position: Position?)]
    var aiRuleNotes: [AIRuleNote]
    var warnings: [String]
    var rationale: String
}

/// What the AI said about a rule. Shown as "AI-assessed" — never as verified compliance.
public struct AIRuleNote: Codable, Sendable, Hashable {
    public var rule: String
    public var satisfied: Bool?
    public var details: String

    public init(rule: String, satisfied: Bool?, details: String) {
        self.rule = rule
        self.satisfied = satisfied
        self.details = details
    }
}

extension BattingOrderResponse {
    func mapped(ids: PromptIDs, players: [PlayerSnapshot]) -> MappedBattingOrder {
        var order: [PlayerID] = []
        var reasons: [PlayerID: String] = [:]
        var unresolved = 0
        let sorted = batting_order.enumerated().sorted { ($0.element.order ?? $0.offset + 1, $0.offset) < ($1.element.order ?? $1.offset + 1, $1.offset) }
        for (_, entry) in sorted {
            guard let id = entry.player_id.resolve(ids: ids, players: players) else { unresolved += 1; continue }
            order.append(id)
            if let reasoning = entry.reasoning, reasons[id] == nil { reasons[id] = ids.humanize(reasoning, players: players) }
        }
        return MappedBattingOrder(order: order, reasons: reasons, unresolved: unresolved, rationale: ids.humanize(rationale ?? "", players: players))
    }
}

extension DefenseResponse {
    func mapped(ids: PromptIDs, players: [PlayerSnapshot], innings: Int) -> MappedDefense {
        var result: [InningAssignment] = []
        var reasons: [String] = []
        var unresolved: [(Int, Position?)] = []
        let sorted = defense.enumerated().sorted { ($0.element.inning ?? $0.offset + 1, $0.offset) < ($1.element.inning ?? $1.offset + 1, $1.offset) }
        for (offset, inning) in sorted.map(\.element).enumerated() {
            var assignment = InningAssignment()
            for (position, ref) in inning.positions {
                guard ref.id != nil || ref.name != nil else { continue }
                if let id = ref.resolve(ids: ids, players: players) {
                    assignment.positions[position] = id
                } else {
                    unresolved.append((offset + 1, position))
                }
            }
            for ref in inning.sit {
                if let id = ref.resolve(ids: ids, players: players) { assignment.sitting.append(id) } else { unresolved.append((offset + 1, nil)) }
            }
            result.append(assignment)
            reasons.append(ids.humanize(inning.reasoning ?? "", players: players))
        }
        let notes = (rules_check ?? []).map { AIRuleNote(rule: $0.rule, satisfied: $0.satisfied, details: ids.humanize($0.details ?? "", players: players)) }
        return MappedDefense(
            innings: result, inningReasons: reasons, unresolved: unresolved, aiRuleNotes: notes,
            warnings: (warnings ?? []).map { ids.humanize($0, players: players) },
            rationale: ids.humanize(rationale ?? "", players: players)
        )
    }
}
