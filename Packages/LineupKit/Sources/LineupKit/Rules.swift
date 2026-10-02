import Foundation

/// A coach's rule, written in plain language. The AI always reads `text`.
/// When `check` is set, the validator also verifies it in code.
public struct TeamRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var enabled: Bool
    public var check: RuleCheck?

    public init(id: UUID = UUID(), text: String, enabled: Bool = true, check: RuleCheck? = nil) {
        self.id = id
        self.text = text
        self.enabled = enabled
        self.check = check
    }
}

/// Rule shapes the validator can verify. A rule without one is "AI judgment only".
public enum RuleCheck: Codable, Sendable, Hashable {
    /// Every player plays at least `n` innings in the field (of the innings they're available).
    case minFieldInnings(Int)
    /// No player sits more than `n` innings.
    case maxSitInnings(Int)
    /// No player sits more than `n` innings in a row.
    case maxConsecutiveSits(Int)
    /// Every player plays at least one infield inning by the end of inning `n`.
    case infieldBy(inning: Int)
    /// No player pitches more than `n` innings.
    case maxPitchingInnings(Int)
    /// No player catches more than `n` innings.
    case maxCatchingInnings(Int)
    /// No player plays the same position more than `n` innings.
    case maxInningsAtOnePosition(Int)
    /// A player who caught `n`+ innings may not pitch in the same game.
    case catcherCannotPitchAfter(Int)

    public static let catalog: [RuleCheck] = [
        .minFieldInnings(3), .maxSitInnings(2), .maxConsecutiveSits(1), .infieldBy(inning: 4),
        .maxPitchingInnings(2), .maxCatchingInnings(3), .maxInningsAtOnePosition(3), .catcherCannotPitchAfter(4),
    ]

    public enum Kind: String, CaseIterable, Sendable {
        case minFieldInnings, maxSitInnings, maxConsecutiveSits, infieldBy
        case maxPitchingInnings, maxCatchingInnings, maxInningsAtOnePosition, catcherCannotPitchAfter
    }

    public var kind: Kind {
        switch self {
        case .minFieldInnings: .minFieldInnings
        case .maxSitInnings: .maxSitInnings
        case .maxConsecutiveSits: .maxConsecutiveSits
        case .infieldBy: .infieldBy
        case .maxPitchingInnings: .maxPitchingInnings
        case .maxCatchingInnings: .maxCatchingInnings
        case .maxInningsAtOnePosition: .maxInningsAtOnePosition
        case .catcherCannotPitchAfter: .catcherCannotPitchAfter
        }
    }

    public var value: Int {
        switch self {
        case .minFieldInnings(let n), .maxSitInnings(let n), .maxConsecutiveSits(let n),
             .maxPitchingInnings(let n), .maxCatchingInnings(let n), .maxInningsAtOnePosition(let n),
             .catcherCannotPitchAfter(let n):
            n
        case .infieldBy(let inning):
            inning
        }
    }

    public static func make(_ kind: Kind, _ n: Int) -> RuleCheck {
        switch kind {
        case .minFieldInnings: .minFieldInnings(n)
        case .maxSitInnings: .maxSitInnings(n)
        case .maxConsecutiveSits: .maxConsecutiveSits(n)
        case .infieldBy: .infieldBy(inning: n)
        case .maxPitchingInnings: .maxPitchingInnings(n)
        case .maxCatchingInnings: .maxCatchingInnings(n)
        case .maxInningsAtOnePosition: .maxInningsAtOnePosition(n)
        case .catcherCannotPitchAfter: .catcherCannotPitchAfter(n)
        }
    }

    /// "Understood as: …" text shown under the rule.
    public var summary: String {
        switch self {
        case .minFieldInnings(let n): "Every player fields at least \(n) innings"
        case .maxSitInnings(let n): "No player sits more than \(n) innings"
        case .maxConsecutiveSits(let n): "No player sits more than \(n) innings in a row"
        case .infieldBy(let inning): "Every player plays infield by the end of inning \(inning)"
        case .maxPitchingInnings(let n): "No player pitches more than \(n) innings"
        case .maxCatchingInnings(let n): "No player catches more than \(n) innings"
        case .maxInningsAtOnePosition(let n): "No player plays one position more than \(n) innings"
        case .catcherCannotPitchAfter(let n): "A player who catches \(n)+ innings can't pitch"
        }
    }
}
