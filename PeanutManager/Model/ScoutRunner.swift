import Foundation
import LineupKit
import LineupAI

/// Runs the Scout for players and teams and saves what comes back. App-wide, so an assessment
/// keeps going when the coach moves to another screen.
@Observable
final class ScoutRunner {
    static let shared = ScoutRunner()

    /// Players being assessed right now.
    private(set) var assessing: Set<UUID> = []
    /// Teams being assessed, with how many of their players are done.
    private(set) var teamProgress: [UUID: (done: Int, total: Int)] = [:]
    var errors: [UUID: String] = [:]

    private var scout: Scout {
        var client: any LLMClient = OpenRouterClient(apiKey: Keychain.apiKey)
        #if DEBUG
        if DebugSupport.fakeAI { client = FakeLLMClient() }
        #endif
        return Scout(client: client, model: ModelLibrary.shared.selectedID)
    }

    func isStale(_ player: Player) -> Bool {
        guard let assessment = player.assessment else { return false }
        return assessment.facts.fingerprint != FactSheet.player(player.snapshot).fingerprint
    }

    func assess(_ player: Player) {
        guard !assessing.contains(player.uid) else { return }
        let snapshot = player.snapshot
        let ageGroup = player.team?.ageGroup
        let scout = scout
        assessing.insert(player.uid)
        errors[player.uid] = nil
        Task {
            defer { assessing.remove(player.uid) }
            do {
                player.assessment = try await scout.assess(snapshot, ageGroup: ageGroup)
            } catch {
                errors[player.uid] = error.localizedDescription
            }
        }
    }

    /// Re-assesses players whose inputs changed (or who were never assessed), then the team.
    func assessTeam(_ team: Team) {
        guard teamProgress[team.uid] == nil else { return }
        let players = team.activePlayers
        let toAssess = players.filter { $0.isAssessable && ($0.assessment == nil || isStale($0)) }
        let snapshots = toAssess.map(\.snapshot)
        let ageGroup = team.ageGroup
        let scout = scout
        teamProgress[team.uid] = (0, toAssess.count)
        errors[team.uid] = nil
        assessing.formUnion(toAssess.map(\.uid))

        Task {
            defer {
                teamProgress[team.uid] = nil
                assessing.subtract(toAssess.map(\.uid))
            }
            do {
                try await withThrowingTaskGroup(of: (Int, PlayerAssessment).self) { group in
                    var next = 0
                    func start() {
                        guard next < snapshots.count else { return }
                        let index = next, snapshot = snapshots[index]
                        group.addTask { (index, try await scout.assess(snapshot, ageGroup: ageGroup)) }
                        next += 1
                    }
                    for _ in 0..<3 { start() } // a few at a time, to stay under rate limits
                    while let (index, assessment) = try await group.next() {
                        toAssess[index].assessment = assessment
                        assessing.remove(toAssess[index].uid)
                        teamProgress[team.uid]?.done += 1
                        start()
                    }
                }
                let assessed = players.filter { $0.assessment != nil }
                var latest: [PlayerID: PlayerAssessment] = [:]
                for player in assessed { latest[player.uid] = player.assessment }
                team.assessment = try await scout.assessTeam(assessed.map(\.snapshot), assessments: latest, ageGroup: ageGroup)
            } catch {
                errors[team.uid] = error.localizedDescription
            }
        }
    }
}
