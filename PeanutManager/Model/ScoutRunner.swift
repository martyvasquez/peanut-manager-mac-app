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
            var failures: [String] = []
            await withTaskGroup(of: (Int, Result<PlayerAssessment, Error>).self) { group in
                var next = 0
                func start() {
                    guard next < snapshots.count else { return }
                    let index = next, snapshot = snapshots[index]
                    group.addTask {
                        do { return (index, .success(try await scout.assess(snapshot, ageGroup: ageGroup))) }
                        catch { return (index, .failure(error)) }
                    }
                    next += 1
                }
                for _ in 0..<3 { start() } // a few at a time, to stay under rate limits
                while let (index, result) = await group.next() {
                    let player = toAssess[index]
                    switch result {
                    case .success(let assessment): player.assessment = assessment
                    case .failure(let error):
                        errors[player.uid] = error.localizedDescription
                        failures.append(error.localizedDescription)
                    }
                    assessing.remove(player.uid)
                    teamProgress[team.uid]?.done += 1
                    start()
                }
            }
            // Every player failed: say why once, and don't spend on a team assessment with nothing new.
            if !failures.isEmpty, failures.count == snapshots.count {
                errors[team.uid] = failures[0]
                return
            }
            do {
                let assessed = players.filter { $0.assessment != nil }
                var latest: [PlayerID: PlayerAssessment] = [:]
                for player in assessed { latest[player.uid] = player.assessment }
                team.assessment = try await scout.assessTeam(assessed.map(\.snapshot), assessments: latest, ageGroup: ageGroup)
                if !failures.isEmpty {
                    errors[team.uid] = "\(failures.count) player\(failures.count == 1 ? "" : "s") couldn't be assessed: \(failures[0])"
                }
            } catch {
                errors[team.uid] = error.localizedDescription
            }
        }
    }
}
