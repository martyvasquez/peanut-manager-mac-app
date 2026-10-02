import Foundation

/// v1's five-step "Win ↔ Develop" slider.
public enum GamePriority: String, CaseIterable, Codable, Sendable {
    case win
    case winLeaning = "win-leaning"
    case balanced
    case devLeaning = "dev-leaning"
    case develop

    public var label: String {
        switch self {
        case .win: "Win"
        case .winLeaning: "Lean Win"
        case .balanced: "Balanced"
        case .devLeaning: "Lean Develop"
        case .develop: "Develop"
        }
    }
}

/// v1's "trust the stats ↔ trust my eye" knob.
public enum DataWeighting: String, CaseIterable, Codable, Sendable {
    case gcOnly = "gc-only"
    case gcHeavy = "gc-heavy"
    case equal
    case coachHeavy = "coach-heavy"
    case coachOnly = "coach-only"

    public var label: String {
        switch self {
        case .gcOnly: "Stats Only"
        case .gcHeavy: "Mostly Stats"
        case .equal: "Stats + Ratings"
        case .coachHeavy: "Mostly Ratings"
        case .coachOnly: "Ratings Only"
        }
    }

    public var usesRatings: Bool { self != .gcOnly }
    public var usesStats: Bool { self != .coachOnly }
}

/// Whether and when a player is at today's game.
public struct Availability: Codable, Sendable, Hashable {
    public var present: Bool
    /// First inning the player can play (late arrival). nil = from the start.
    public var arrivesInning: Int?
    /// Last inning the player can play (leaves early). nil = through the end.
    public var leavesAfterInning: Int?
    /// Game-specific note from the coach ("sore arm — no pitching").
    public var note: String

    public init(present: Bool = true, arrivesInning: Int? = nil, leavesAfterInning: Int? = nil, note: String = "") {
        self.present = present
        self.arrivesInning = arrivesInning
        self.leavesAfterInning = leavesAfterInning
        self.note = note
    }

    public static let present = Availability()
    public static let absent = Availability(present: false)

    public func isAvailable(inning: Int) -> Bool {
        guard present else { return false }
        if let arrives = arrivesInning, inning < arrives { return false }
        if let leaves = leavesAfterInning, inning > leaves { return false }
        return true
    }

    public var isPartial: Bool { present && (arrivesInning != nil || leavesAfterInning != nil) }
}

/// Everything about one game that the AI and the validator need.
public struct GameContext: Sendable {
    public var innings: Int
    /// Every active player on the team; `availability` says who is here.
    public var players: [PlayerSnapshot]
    public var availability: [PlayerID: Availability]
    public var rules: [TeamRule]
    public var priority: GamePriority
    public var weighting: DataWeighting
    public var locks: [Lock]
    public var ageGroup: String?
    public var scoutingReport: String
    public var notesForAI: String

    public init(
        innings: Int,
        players: [PlayerSnapshot],
        availability: [PlayerID: Availability] = [:],
        rules: [TeamRule] = [],
        priority: GamePriority = .balanced,
        weighting: DataWeighting = .equal,
        locks: [Lock] = [],
        ageGroup: String? = nil,
        scoutingReport: String = "",
        notesForAI: String = ""
    ) {
        self.innings = innings
        self.players = players
        self.availability = availability
        self.rules = rules
        self.priority = priority
        self.weighting = weighting
        self.locks = locks
        self.ageGroup = ageGroup
        self.scoutingReport = scoutingReport
        self.notesForAI = notesForAI
    }

    public func availability(of player: PlayerID) -> Availability {
        availability[player] ?? .present
    }

    /// Players at the game at all, in roster order. Everyone here bats.
    public var presentPlayers: [PlayerSnapshot] {
        players.filter { availability(of: $0.id).present }
    }

    public func availablePlayers(inning: Int) -> [PlayerSnapshot] {
        players.filter { availability(of: $0.id).isAvailable(inning: inning) }
    }

    public func player(_ id: PlayerID) -> PlayerSnapshot? {
        players.first { $0.id == id }
    }

    public func name(_ id: PlayerID) -> String {
        player(id)?.name ?? "Unknown player"
    }

    public var activeRules: [TeamRule] { rules.filter(\.enabled) }
}
