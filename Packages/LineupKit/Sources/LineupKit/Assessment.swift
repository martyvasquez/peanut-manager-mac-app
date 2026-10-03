import Foundation

/// A claim the Scout makes, backed by fact IDs. The UI renders the cited facts' real values,
/// so the AI never writes a number the coach has to trust.
public struct Claim: Codable, Sendable, Hashable {
    public var title: String
    public var detail: String
    public var evidence: [String]

    public init(title: String, detail: String, evidence: [String] = []) {
        self.title = title
        self.detail = detail
        self.evidence = evidence
    }
}

public enum BattingZone: String, Codable, Sendable, CaseIterable {
    case top, middle, bottom
}

public enum PositionFit: String, Codable, Sendable, CaseIterable, Comparable {
    case strong, solid, developing
    case notRecommended = "not_recommended"

    public var label: String {
        switch self {
        case .strong: "Strong"
        case .solid: "Solid"
        case .developing: "Developing"
        case .notRecommended: "Not recommended"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: PositionFit, rhs: PositionFit) -> Bool { lhs.rank < rhs.rank }
}

public enum Confidence: String, Codable, Sendable {
    case high, medium, low
}

public struct DefensiveFit: Codable, Sendable, Hashable {
    public var position: Position
    public var fit: PositionFit
    public var reason: String
    public var evidence: [String]
}

public struct DevelopmentFocus: Codable, Sendable, Hashable {
    public var focus: String
    public var drill: String
}

/// The Scout's view of one player (plan §5.1), cached until its inputs change.
public struct PlayerAssessment: Codable, Sendable, Hashable {
    public var snapshot: String
    public var strengths: [Claim]
    public var weaknesses: [Claim]
    public var battingRole: String
    public var battingZone: BattingZone?
    public var battingReason: String
    public var defense: [DefensiveFit]
    public var eyeVsData: String?
    public var development: [DevelopmentFocus]
    public var confidence: Confidence
    public var confidenceReason: String

    /// What the assessment was made from; it's stale when the player's facts no longer match.
    public var facts: FactSheet
    public var model: String
    public var cost: Double?
    public var assessedAt: Date
}

public struct PracticeItem: Codable, Sendable, Hashable {
    public enum Priority: String, Codable, Sendable { case high, medium, low }
    public var focus: String
    public var drills: String
    public var priority: Priority
}

/// The Scout's view of the team (plan §5.2).
public struct TeamAssessment: Codable, Sendable, Hashable {
    public var summary: String
    public var strengths: [Claim]
    public var weaknesses: [Claim]
    public var leadoff: [PlayerID]
    public var middleOrder: [PlayerID]
    public var defensiveCore: [PlayerID]
    public var defensiveConcerns: [String]
    public var practice: [PracticeItem]

    /// Team facts plus every player's, keyed "P3.obp"-style as the prompt showed them.
    public var facts: FactSheet
    public var model: String
    public var cost: Double?
    public var assessedAt: Date
}

// MARK: - Raw AI output

struct PlayerAssessmentResponse: Decodable {
    struct RawClaim: Decodable {
        var category: String?
        var title: String?
        var description: String?
        var evidence: [String]?

        var claim: Claim { Claim(title: title ?? category ?? "", detail: description ?? "", evidence: evidence ?? []) }
    }
    struct Batting: Decodable {
        var role: String?
        var zone: String?
        var reason: String?
    }
    struct Defense: Decodable {
        var position: String
        var fit: String
        var reason: String?
        var evidence: [String]?
    }
    struct Focus: Decodable {
        var focus: String?
        var drill: String?
    }
    struct Confidence: Decodable {
        var level: String?
        var reason: String?
    }

    var summary: String?
    var strengths: [RawClaim]?
    var weaknesses: [RawClaim]?
    var batting: Batting?
    var defense: [Defense]?
    var eye_vs_data: String?
    var development_focus: [Focus]?
    var data_confidence: Confidence?
}

struct TeamAssessmentResponse: Decodable {
    struct Practice: Decodable {
        var focus_area: String?
        var drill_suggestions: String?
        var priority: String?
    }
    struct Insights: Decodable {
        var best_leadoff_candidates: [PlayerRef]?
        var middle_of_order: [PlayerRef]?
        var defensive_core: [PlayerRef]?
        var defensive_concerns: [String]?
    }

    var team_strengths: [PlayerAssessmentResponse.RawClaim]?
    var team_weaknesses: [PlayerAssessmentResponse.RawClaim]?
    var practice_recommendations: [Practice]?
    var lineup_insights: Insights?
    var summary: String?
}

// MARK: - Grounding check

enum Grounding {
    /// Problems the model must fix: citations of facts that don't exist, and unreadable fields.
    static func problems(_ claims: [Claim], defense: [DefensiveFit] = [], facts: FactSheet) -> [String] {
        var problems: [String] = []
        for claim in claims {
            for id in claim.evidence where !facts.contains(id) {
                problems.append("\"\(claim.title)\" cites [\(id)], which isn't in the fact sheet.")
            }
        }
        for fit in defense {
            for id in fit.evidence where !facts.contains(id) {
                problems.append("The \(fit.position.label) fit cites [\(id)], which isn't in the fact sheet.")
            }
        }
        return problems
    }

    /// After the one retry: drop citations that still don't resolve rather than show them.
    static func keepingResolved(_ claim: Claim, facts: FactSheet) -> Claim {
        var claim = claim
        claim.evidence = claim.evidence.filter(facts.contains)
        return claim
    }
}
