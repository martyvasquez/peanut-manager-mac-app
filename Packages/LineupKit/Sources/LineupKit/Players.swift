import Foundation

public typealias PlayerID = UUID

/// The 14 coach ratings carried over from v1 (1–5 stars; missing means unrated, never "average").
public enum RatingKey: String, CaseIterable, Codable, Sendable, CodingKeyRepresentable {
    case plateDiscipline = "plate_discipline"
    case contactAbility = "contact_ability"
    case battingPower = "batting_power"
    case runSpeed = "run_speed"
    case baseballIQ = "baseball_iq"
    case attention
    case fieldingHands = "fielding_hands"
    case throwAccuracy = "fielding_throw_accuracy"
    case armStrength = "fielding_arm_strength"
    case flyBallAbility = "fly_ball_ability"
    case pitchControl = "pitch_control"
    case pitchVelocity = "pitch_velocity"
    case pitchComposure = "pitch_composure"
    case catcherAbility = "catcher_ability"

    public var label: String {
        switch self {
        case .plateDiscipline: "Plate Discipline"
        case .contactAbility: "Contact Ability"
        case .battingPower: "Power"
        case .runSpeed: "Run Speed"
        case .baseballIQ: "Baseball IQ"
        case .attention: "Attention"
        case .fieldingHands: "Fielding Hands"
        case .throwAccuracy: "Throw Accuracy"
        case .armStrength: "Arm Strength"
        case .flyBallAbility: "Fly Ball Ability"
        case .pitchControl: "Pitch Control"
        case .pitchVelocity: "Pitch Velocity"
        case .pitchComposure: "Pitch Composure"
        case .catcherAbility: "Catcher Ability"
        }
    }

    public enum Group: String, CaseIterable, Sendable {
        case batting = "Batting", athletic = "Athletic", fielding = "Fielding", pitching = "Pitching", catching = "Catching"
    }

    public var group: Group {
        switch self {
        case .plateDiscipline, .contactAbility, .battingPower: .batting
        case .runSpeed, .baseballIQ, .attention: .athletic
        case .fieldingHands, .throwAccuracy, .armStrength, .flyBallAbility: .fielding
        case .pitchControl, .pitchVelocity, .pitchComposure: .pitching
        case .catcherAbility: .catching
        }
    }
}

public struct Ratings: Codable, Sendable, Hashable {
    public var values: [RatingKey: Int]

    public init(_ values: [RatingKey: Int] = [:]) {
        self.values = values
    }

    public subscript(key: RatingKey) -> Int? {
        get { values[key] }
        set { values[key] = newValue.map { min(max($0, 1), 5) } }
    }

    public var isEmpty: Bool { values.isEmpty }
}

/// Everything the engine needs to know about one player. Value type; the app maps its stored models into this.
public struct PlayerSnapshot: Identifiable, Codable, Sendable, Hashable {
    public var id: PlayerID
    public var name: String
    public var jersey: String?
    public var notes: String
    public var profile: PositionProfile
    public var ratings: Ratings
    public var stats: PlayerStats?

    public init(
        id: PlayerID = UUID(),
        name: String,
        jersey: String? = nil,
        notes: String = "",
        profile: PositionProfile = .default,
        ratings: Ratings = Ratings(),
        stats: PlayerStats? = nil
    ) {
        self.id = id
        self.name = name
        self.jersey = jersey
        self.notes = notes
        self.profile = profile
        self.ratings = ratings
        self.stats = stats
    }
}
