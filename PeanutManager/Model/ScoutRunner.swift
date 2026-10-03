import Foundation
import SwiftData
import LineupKit
import LineupAI

/// Where one player's assessment is, so the coach can see progress and problems as they happen.
enum ScoutJob: Equatable {
    case waiting
    case running(since: Date)
    case retrying(attempt: Int, reason: String)
    case failed(String)

    var isActive: Bool {
        if case .failed = self { false } else { true }
    }
}

/// Runs the Scout for players and teams and saves each result as soon as it arrives, so an
/// interrupted run loses nothing and the next one picks up where it stopped. App-wide, so work
/// keeps going when the coach moves to another screen.
@Observable
final class ScoutRunner {
    static let shared = ScoutRunner()

    /// Players queued, running, retrying, or failed in this session. Done players are removed.
    private(set) var jobs: [UUID: ScoutJob] = [:]
    /// Teams with a run in progress; `writingSummary` once every player is done.
    private(set) var teamRuns: [UUID: (total: Int, writingSummary: Bool)] = [:]
    /// Run-level problems, by team (or player, for a one-off assessment).
    var errors: [UUID: String] = [:]

    private static let attempts = 3
    private static let concurrent = 3

    private var scout: Scout {
        let ai = AIService.shared.client()
        return Scout(client: ai.client, model: ai.model)
    }

    // MARK: - Status

    func isStale(_ player: Player) -> Bool {
        guard let assessment = player.assessment else { return false }
        return assessment.facts.fingerprint != FactSheet.player(player.snapshot).fingerprint
    }

    func isBusy(_ player: Player) -> Bool { jobs[player.uid]?.isActive ?? false }

    /// Assessable players with no assessment, or one made from inputs that have since changed.
    func needingAssessment(_ team: Team) -> [Player] {
        team.activePlayers.filter { $0.isAssessable && ($0.assessment == nil || isStale($0)) }
    }

    /// Whether the team summary reflects every assessable player as they're assessed now.
    func isTeamCurrent(_ team: Team) -> Bool {
        guard let summary = team.assessment else { return false }
        let players = team.activePlayers.filter(\.isAssessable)
        guard needingAssessment(team).isEmpty, Set(summary.players ?? []) == Set(players.map(\.uid)) else { return false }
        return players.allSatisfy { ($0.assessment?.assessedAt ?? .distantFuture) <= summary.assessedAt }
    }

    // MARK: - Running

    func assess(_ player: Player) {
        guard !isBusy(player) else { return }
        let snapshot = player.snapshot
        let ageGroup = player.team?.ageGroup
        let scout = scout
        jobs[player.uid] = .waiting
        errors[player.uid] = nil
        Task {
            do {
                try await run(player, snapshot: snapshot, scout: scout, ageGroup: ageGroup)
            } catch {
                errors[player.uid] = Self.message(error)
            }
        }
    }

    /// Assesses every player who needs it, then writes the team summary once all of them are done.
    /// Retries timeouts and rate limits by itself; stops at once on problems a retry can't fix.
    func assessTeam(_ team: Team) {
        guard teamRuns[team.uid] == nil else { return }
        let queue = needingAssessment(team)
        let snapshots = queue.map(\.snapshot)
        let ageGroup = team.ageGroup
        let scout = scout
        for player in queue { jobs[player.uid] = .waiting }
        teamRuns[team.uid] = (queue.count, false)
        errors[team.uid] = nil

        Task {
            defer { teamRuns[team.uid] = nil }
            // A few workers take players from one queue; each request still runs off the main thread.
            let work = WorkQueue(queue.indices.map { (queue[$0], snapshots[$0]) })
            let workers = (0..<Self.concurrent).map { _ in
                Task {
                    while work.fatal == nil, let (player, snapshot) = work.next() {
                        do {
                            try await self.run(player, snapshot: snapshot, scout: scout, ageGroup: ageGroup)
                        } catch where Self.isFatal(error) {
                            work.fatal = error
                        } catch {
                            // Recorded on the player; the others carry on.
                        }
                    }
                }
            }
            for worker in workers { await worker.value }
            if let fatal = work.fatal {
                // A bad key or no credits: nothing else will work either.
                for player in queue where jobs[player.uid]?.isActive == true { jobs[player.uid] = nil }
                errors[team.uid] = Self.message(fatal)
                return
            }

            let failed = queue.filter { if case .failed = jobs[$0.uid] { true } else { false } }
            guard failed.isEmpty else {
                errors[team.uid] = "\(failed.count) of \(queue.count) players couldn't be assessed. The team summary waits until everyone is done."
                return
            }

            teamRuns[team.uid]?.writingSummary = true
            let players = team.activePlayers.filter { $0.assessment != nil }
            var latest: [PlayerID: PlayerAssessment] = [:]
            for player in players { latest[player.uid] = player.assessment }
            do {
                let summary = try await withRetries { try await scout.assessTeam(players.map(\.snapshot), assessments: latest, ageGroup: ageGroup) }
                team.assessment = summary
                try? team.modelContext?.save()
            } catch {
                errors[team.uid] = "The team summary couldn't be written: \(Self.message(error))"
            }
        }
    }

    /// One player, with retries. Saves the result the moment it arrives.
    private func run(_ player: Player, snapshot: PlayerSnapshot, scout: Scout, ageGroup: String?) async throws {
        do {
            let assessment = try await withRetries(onRetry: { attempt, error in
                self.jobs[player.uid] = .retrying(attempt: attempt, reason: Self.message(error))
            }, onStart: {
                self.jobs[player.uid] = .running(since: .now)
            }) {
                try await scout.assess(snapshot, ageGroup: ageGroup)
            }
            player.assessment = assessment
            try? player.modelContext?.save()
            jobs[player.uid] = nil
        } catch {
            jobs[player.uid] = Self.isFatal(error) ? nil : .failed(Self.isTransient(error) ? "Tried \(Self.attempts) times. \(Self.message(error))" : Self.message(error))
            throw error
        }
    }

    /// Tries up to `attempts` times, waiting longer each time, unless the error can't be fixed by trying again.
    private func withRetries<T>(
        onRetry: (Int, Error) -> Void = { _, _ in },
        onStart: () -> Void = {},
        _ body: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            onStart()
            do {
                return try await body()
            } catch {
                guard attempt < Self.attempts, !Self.isFatal(error), !(error is CancellationError) else { throw error }
                onRetry(attempt + 1, error)
                try await Task.sleep(for: .seconds(attempt == 1 ? 10 : 30))
                attempt += 1
            }
        }
    }

    private final class WorkQueue {
        private var items: [(Player, PlayerSnapshot)]
        var fatal: Error?
        init(_ items: [(Player, PlayerSnapshot)]) { self.items = items }
        func next() -> (Player, PlayerSnapshot)? { items.isEmpty ? nil : items.removeFirst() }
    }

    // MARK: - Errors

    /// Problems that won't go away by trying again.
    static func isFatal(_ error: Error) -> Bool { AIService.isFatal(error) }

    /// Problems that usually clear up on their own: timeouts, dropped connections, rate limits, server errors.
    static func isTransient(_ error: Error) -> Bool { AIService.isTransient(error) }

    static func message(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "The model took too long to answer."
            case .notConnectedToInternet, .networkConnectionLost: return "The connection dropped."
            default: break
            }
        }
        return error.localizedDescription
    }
}
