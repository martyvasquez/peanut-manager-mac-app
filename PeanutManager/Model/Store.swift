import Foundation
import SwiftData
import LineupKit

// Local SwiftData store. Structured values (profiles, ratings, stats, lineups) are stored as JSON blobs
// of LineupKit types so the domain package stays the single source of truth for their shape.
//
// Ready for iCloud (CloudKit) sync: every attribute has a default or is optional, every relationship is
// optional with an inverse, and nothing is unique. Once the schema is in production it can only grow.
// Anything about a kid is end-to-end encrypted in iCloud (`.allowsCloudEncryption`), and that choice
// can't be changed later, so new fields about kids need it from the start.

@Model
final class Team {
    var uid = UUID()
    var name = ""
    var ageGroup = ""
    var defaultInnings = 6
    var createdAt = Date.now
    var statsImportedAt: Date?
    @Attribute(.allowsCloudEncryption) var assessmentData: Data?

    @Relationship(deleteRule: .cascade, originalName: "players", inverse: \Player.team) var playerList: [Player]?
    @Relationship(deleteRule: .cascade, originalName: "ruleSets", inverse: \RuleSet.team) var ruleSetList: [RuleSet]?
    @Relationship(deleteRule: .cascade, originalName: "games", inverse: \Game.team) var gameList: [Game]?

    init(name: String, ageGroup: String = "", defaultInnings: Int = 6) {
        self.name = name
        self.ageGroup = ageGroup
        self.defaultInnings = defaultInnings
    }

    var players: [Player] { playerList ?? [] }
    var ruleSets: [RuleSet] { ruleSetList ?? [] }
    var games: [Game] { gameList ?? [] }

    var activePlayers: [Player] { players.filter(\.active).sorted { $0.sortIndex < $1.sortIndex } }
    var sortedPlayers: [Player] { players.sorted { ($0.active ? 0 : 1, $0.sortIndex) < ($1.active ? 0 : 1, $1.sortIndex) } }
    var sortedRuleSets: [RuleSet] { ruleSets.sorted { $0.createdAt < $1.createdAt } }

    var assessment: TeamAssessment? {
        get { assessmentData.flatMap { try? JSONDecoder().decode(TeamAssessment.self, from: $0) } }
        set { assessmentData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

@Model
final class Player {
    var uid = UUID()
    @Attribute(.allowsCloudEncryption) var name = ""
    @Attribute(.allowsCloudEncryption) var jersey = ""
    var active = true
    @Attribute(.allowsCloudEncryption) var notes = ""
    var sortIndex = 0
    @Attribute(.allowsCloudEncryption) var profileData = Data()
    @Attribute(.allowsCloudEncryption) var ratingsData = Data()
    @Attribute(.allowsCloudEncryption) var statsData: Data?
    @Attribute(.allowsCloudEncryption) var assessmentData: Data?
    var team: Team?

    init(name: String, jersey: String = "", sortIndex: Int = 0) {
        self.name = name
        self.jersey = jersey
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

    /// Turns on positions the player has actually played in GameChanger: pitched → P, caught → C,
    /// most-played position → best. Only touches players whose positions were never edited,
    /// so a coach's deliberate "can't" is kept. Returns whether anything changed.
    @discardableResult
    func applyGameChangerHistory() -> Bool {
        guard let stats, profile == .default else { return false }
        var p = profile
        if (stats.pitching?.outs ?? 0) > 0 { p[.p] = .can }
        if let f = stats.fielding {
            if f.catcherOuts > 0 || (f.innings[.c] ?? 0) > 0 { p[.c] = .can }
            if let top = f.innings.filter({ $0.value > 0 }).max(by: { $0.value < $1.value })?.key { p[top] = .primary }
        }
        guard p != profile else { return false }
        profile = p
        return true
    }

    var assessment: PlayerAssessment? {
        get { assessmentData.flatMap { try? JSONDecoder().decode(PlayerAssessment.self, from: $0) } }
        set { assessmentData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// The Scout needs season stats to work from; ratings and notes add to them but can't stand alone.
    var isAssessable: Bool { stats != nil }

    var snapshot: PlayerSnapshot {
        PlayerSnapshot(id: uid, name: name, jersey: jersey.isEmpty ? nil : jersey, notes: notes, profile: profile, ratings: ratings, stats: stats)
    }
}

@Model
final class RuleSet {
    var name = ""
    var createdAt = Date.now
    var team: Team?
    @Relationship(deleteRule: .cascade, originalName: "rules", inverse: \Rule.ruleSet) var ruleList: [Rule]?
    /// Games played under this rule set; deleting the set leaves them without one.
    @Relationship(deleteRule: .nullify, inverse: \Game.ruleSet) var gameList: [Game]?

    init(name: String) {
        self.name = name
    }

    var rules: [Rule] { ruleList ?? [] }
    var sortedRules: [Rule] { rules.sorted { $0.order < $1.order } }
}

@Model
final class Rule {
    var uid = UUID()
    @Attribute(.allowsCloudEncryption) var text = ""
    var enabled = true
    var order = 0
    var checkData: Data?
    var ruleSet: RuleSet?

    init(text: String, order: Int, check: RuleCheck? = nil) {
        self.text = text
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
    var opponent = ""
    var date = Date.now
    var innings = 6
    var priorityRaw = GamePriority.balanced.rawValue
    var weightingRaw = DataWeighting.equal.rawValue
    @Attribute(.allowsCloudEncryption) var scoutingReport = ""
    @Attribute(.allowsCloudEncryption) var notesForAI = ""
    var ourScore: Int?
    var theirScore: Int?
    @Attribute(.allowsCloudEncryption) var availabilityData = Data()
    @Attribute(.allowsCloudEncryption) var documentData: Data?
    @Attribute(.allowsCloudEncryption) var historyData = Data()
    var ruleSet: RuleSet?
    var team: Team?

    init(opponent: String, date: Date, innings: Int) {
        self.opponent = opponent
        self.date = date
        self.innings = innings
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

    /// Someone on the team has season stats. Without them the AI can only go by the coach's ratings.
    var hasStats: Bool { team?.activePlayers.contains { $0.stats != nil } == true }

    /// Everything the engine and validator need, assembled from the stored game.
    func context(locks: [Lock] = []) -> GameContext {
        let team = self.team
        return GameContext(
            innings: innings,
            players: team?.activePlayers.map(\.snapshot) ?? [],
            availability: availability,
            rules: ruleSet?.sortedRules.map(\.teamRule) ?? [],
            priority: priority,
            weighting: hasStats ? weighting : .coachOnly,
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
    /// The batting order's spots while the coach builds it by hand and some are still empty (`BattingSlots`).
    /// nil once every spot is filled; `lineup.battingOrder` always has the gaps closed.
    var battingSlots: [PlayerID?]?
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
    /// The model's thinking level when the lineup was made.
    var effort: String?
    var cost: Double?
    var generatedAt: Date?
}

nonisolated struct LineupVersion: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var savedAt: Date
    var label: String
    var document: LineupDocument
}

/// The library's schema. CloudKit allows only additive changes once it's in production, so a later version
/// adds fields or models (with defaults) and never renames or removes them.
nonisolated enum LibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Team.self, Player.self, RuleSet.self, Rule.self, Game.self] }
}
