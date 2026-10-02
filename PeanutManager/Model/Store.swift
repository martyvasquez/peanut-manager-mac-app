import Foundation
import SwiftData
import LineupKit

// Local SwiftData store. Structured values (profiles, ratings, stats, lineups) are stored as JSON blobs
// of LineupKit types so the domain package stays the single source of truth for their shape.

@Model
final class Team {
    var uid: UUID
    var name: String
    var ageGroup: String
    var defaultInnings: Int
    var createdAt: Date
    var statsImportedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Player.team) var players: [Player] = []
    @Relationship(deleteRule: .cascade, inverse: \RuleSet.team) var ruleSets: [RuleSet] = []
    @Relationship(deleteRule: .cascade, inverse: \Game.team) var games: [Game] = []

    init(name: String, ageGroup: String = "", defaultInnings: Int = 6) {
        self.uid = UUID()
        self.name = name
        self.ageGroup = ageGroup
        self.defaultInnings = defaultInnings
        self.createdAt = .now
    }

    var activePlayers: [Player] { players.filter(\.active).sorted { $0.sortIndex < $1.sortIndex } }
    var sortedPlayers: [Player] { players.sorted { ($0.active ? 0 : 1, $0.sortIndex) < ($1.active ? 0 : 1, $1.sortIndex) } }
    var sortedRuleSets: [RuleSet] { ruleSets.sorted { $0.createdAt < $1.createdAt } }
}

@Model
final class Player {
    var uid: UUID
    var name: String
    var jersey: String
    var active: Bool
    var notes: String
    var sortIndex: Int
    var profileData: Data
    var ratingsData: Data
    var statsData: Data?
    var team: Team?

    init(name: String, jersey: String = "", sortIndex: Int = 0) {
        self.uid = UUID()
        self.name = name
        self.jersey = jersey
        self.active = true
        self.notes = ""
        self.sortIndex = sortIndex
        self.profileData = (try? JSONEncoder().encode(PositionProfile.default)) ?? Data()
        self.ratingsData = (try? JSONEncoder().encode(Ratings())) ?? Data()
    }

    var profile: PositionProfile {
        get { (try? JSONDecoder().decode(PositionProfile.self, from: profileData)) ?? .default }
        set { profileData = (try? JSONEncoder().encode(newValue)) ?? profileData }
    }

    var ratings: Ratings {
        get { (try? JSONDecoder().decode(Ratings.self, from: ratingsData)) ?? Ratings() }
        set { ratingsData = (try? JSONEncoder().encode(newValue)) ?? ratingsData }
    }

    var stats: PlayerStats? {
        get { statsData.flatMap { try? JSONDecoder().decode(PlayerStats.self, from: $0) } }
        set { statsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var snapshot: PlayerSnapshot {
        PlayerSnapshot(id: uid, name: name, jersey: jersey.isEmpty ? nil : jersey, notes: notes, profile: profile, ratings: ratings, stats: stats)
    }
}

@Model
final class RuleSet {
    var name: String
    var createdAt: Date
    var team: Team?
    @Relationship(deleteRule: .cascade, inverse: \Rule.ruleSet) var rules: [Rule] = []

    init(name: String) {
        self.name = name
        self.createdAt = .now
    }

    var sortedRules: [Rule] { rules.sorted { $0.order < $1.order } }
}

@Model
final class Rule {
    var uid: UUID
    var text: String
    var enabled: Bool
    var order: Int
    var checkData: Data?
    var ruleSet: RuleSet?

    init(text: String, order: Int, check: RuleCheck? = nil) {
        self.uid = UUID()
        self.text = text
        self.enabled = true
        self.order = order
        self.checkData = check.flatMap { try? JSONEncoder().encode($0) }
    }

    var check: RuleCheck? {
        get { checkData.flatMap { try? JSONDecoder().decode(RuleCheck.self, from: $0) } }
        set { checkData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var teamRule: TeamRule { TeamRule(id: uid, text: text, enabled: enabled, check: check) }
}

@Model
final class Game {
    var opponent: String
    var date: Date
    var innings: Int
    var priorityRaw: String
    var weightingRaw: String
    var scoutingReport: String
    var notesForAI: String
    var ourScore: Int?
    var theirScore: Int?
    var availabilityData: Data
    var documentData: Data?
    var historyData: Data
    @Relationship(deleteRule: .nullify) var ruleSet: RuleSet?
    var team: Team?

    init(opponent: String, date: Date, innings: Int) {
        self.opponent = opponent
        self.date = date
        self.innings = innings
        self.priorityRaw = GamePriority.balanced.rawValue
        self.weightingRaw = DataWeighting.equal.rawValue
        self.scoutingReport = ""
        self.notesForAI = ""
        self.availabilityData = (try? JSONEncoder().encode([PlayerID: Availability]())) ?? Data()
        self.historyData = (try? JSONEncoder().encode([LineupVersion]())) ?? Data()
    }

    var priority: GamePriority {
        get { GamePriority(rawValue: priorityRaw) ?? .balanced }
        set { priorityRaw = newValue.rawValue }
    }

    var weighting: DataWeighting {
        get { DataWeighting(rawValue: weightingRaw) ?? .equal }
        set { weightingRaw = newValue.rawValue }
    }

    var availability: [PlayerID: Availability] {
        get { (try? JSONDecoder().decode([PlayerID: Availability].self, from: availabilityData)) ?? [:] }
        set { availabilityData = (try? JSONEncoder().encode(newValue)) ?? availabilityData }
    }

    var document: LineupDocument? {
        get { documentData.flatMap { try? JSONDecoder().decode(LineupDocument.self, from: $0) } }
        set { documentData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var history: [LineupVersion] {
        get { (try? JSONDecoder().decode([LineupVersion].self, from: historyData)) ?? [] }
        set { historyData = (try? JSONEncoder().encode(Array(newValue.suffix(30)))) ?? historyData }
    }

    var isPast: Bool { Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: .now) }

    /// Everything the engine and validator need, assembled from the stored game.
    func context(locks: [Lock] = []) -> GameContext {
        let team = self.team
        return GameContext(
            innings: innings,
            players: team?.activePlayers.map(\.snapshot) ?? [],
            availability: availability,
            rules: ruleSet?.sortedRules.map(\.teamRule) ?? [],
            priority: priority,
            weighting: weighting,
            locks: locks,
            ageGroup: team?.ageGroup,
            scoutingReport: scoutingReport,
            notesForAI: notesForAI
        )
    }
}

/// The working lineup for a game, with everything the coach needs to trust it.
nonisolated struct LineupDocument: Codable, Hashable, Sendable {
    var lineup = Lineup()
    var locks: [Lock] = []
    var provenance: [CellKey: Provenance] = [:]
    var battingReasons: [PlayerID: String] = [:]
    var battingRationale = ""
    var inningReasons: [String] = []
    var defenseRationale = ""
    var warnings: [String] = []
    var aiRuleNotes: [AIRuleNote] = []
    var revisions = 0
    var appAdjustedCount = 0
    var model = ""
    var cost: Double?
    var generatedAt: Date?
}

nonisolated struct LineupVersion: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var savedAt: Date
    var label: String
    var document: LineupDocument
}
