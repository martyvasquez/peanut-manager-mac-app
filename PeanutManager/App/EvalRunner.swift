#if DEBUG
import AppKit
import Foundation
import Synchronization
import SwiftData
import LineupKit
import LineupAI

/// The model eval (plan, Build status item 5): one hard game and a few players, each model once, one call at a time.
/// Runs only on a copy of the library:
///   -PMStore <Copy> -PMRunEval YES -PMEvalGame <opponent> [-PMEvalRules <rule set>] -PMEvalPlayers "<name>,<name>"
///   [-PMEvalModels "<id>,<id>"] [-PMEvalEffort medium]
/// Writes ~/Library/Application Support/Peanut Manager/Evals/<Copy>/: results.json (finished runs are never
/// repeated), progress.log, and grade.html (blind: A, B, C… until you reveal).
enum EvalRunner {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "PMRunEval") }

    /// Newest model of each family, roughly cheapest first.
    static let families = ["luna", "sol", "terra", "astra"]

    nonisolated static var folder: URL {
        let store = UserDefaults.standard.string(forKey: "PMStore") ?? ""
        return URL.applicationSupportDirectory.appending(path: "Peanut Manager/Evals/\(store)", directoryHint: .isDirectory)
    }

    static func run(container: ModelContainer) async {
        let defaults = UserDefaults.standard
        guard let store = defaults.string(forKey: "PMStore"), !store.isEmpty, store != "Library" else {
            print("Eval: refusing to run on the real library. Copy it and pass -PMStore <Name>.")
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resultsURL = folder.appending(path: "results.json")
        let effort = defaults.string(forKey: "PMEvalEffort") ?? AIService.defaultEffort
        var results = (try? Data(contentsOf: resultsURL)).flatMap { try? JSONDecoder().decode(EvalResults.self, from: $0) } ?? EvalResults(effort: effort)
        func save() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(results).write(to: resultsURL, options: .atomic)
        }

        let ai = AIService.shared
        await ai.loadModels()
        guard ai.isSignedIn, !ai.chatGPTModels.isEmpty else {
            log("Sign in with ChatGPT first. \(ai.modelsError ?? "")")
            return
        }
        let models = pickModels(ai.chatGPTModels)
        log("Models: \(models.map(\.id).joined(separator: ", ")) · thinking \(effort)")

        let context = container.mainContext
        guard let team = (try? context.fetch(FetchDescriptor<Team>()))?.first else { log("No team in this library."); return }
        var stopped = false

        /// One model on one subject, unless it's already done. Returns false once a retry can't help (usage limit, sign-in).
        func attempt(_ kind: String, _ subject: String, _ model: ChatGPTClient.ModelInfo, _ body: (RecordingClient, inout EvalRun) async throws -> Void) async {
            guard !stopped else { return }
            if results.blind[subject] == nil { results.blind[subject] = models.map(\.id).shuffled() }
            for id in models.map(\.id) where !(results.blind[subject]?.contains(id) ?? false) { results.blind[subject]?.append(id) }
            if results.runs.contains(where: { $0.subject == subject && $0.model == model.id && $0.error == nil }) { return }
            results.runs.removeAll { $0.subject == subject && $0.model == model.id }
            let thinking = model.efforts.contains(effort) ? effort : nil
            let client = RecordingClient(ai.client(effort: thinking))
            var run = EvalRun(kind: kind, subject: subject, model: model.id, effort: thinking)
            log("\(kind) \(subject) · \(model.id)")
            do {
                try await body(client, &run)
            } catch {
                run.error = error.localizedDescription
                log("  failed: \(error.localizedDescription)")
                if AIService.isFatal(error) { stopped = true; log("Stopping: a retry won't help.") }
            }
            run.calls = client.recorded
            results.runs.append(run)
            save()
        }

        // Lineup: the chosen game with its locks, optionally under another rule set.
        if let gameName = defaults.string(forKey: "PMEvalGame") {
            if let game = team.games.first(where: { $0.opponent == gameName }) {
                var ctx = game.context(locks: game.document?.locks ?? [])
                var ruleSetName = game.ruleSet?.name ?? ""
                if let name = defaults.string(forKey: "PMEvalRules"), let set = team.ruleSets.first(where: { $0.name == name }) {
                    ctx.rules = set.sortedRules.map(\.teamRule)
                    ruleSetName = name
                }
                results.addPlayers(ctx.players)
                results.lineupCase = LineupCase(
                    game: gameName, ruleSet: ruleSetName, rules: ctx.rules.filter(\.enabled).map(\.text), innings: ctx.innings,
                    locks: ctx.locks.map { EvalLock(inning: $0.inning, player: $0.player.uuidString, slot: $0.slot.description) },
                    absent: ctx.players.filter { !ctx.availability(of: $0.id).present }.map(\.id.uuidString)
                )
                save()
                let feasibility = Validator.feasibility(ctx)
                if feasibility.hasViolations {
                    log("Game \(gameName) can't be lined up as set up: \(feasibility.violations.map(\.message).joined(separator: " "))")
                } else {
                    for model in models {
                        await attempt("lineup", "lineup", model) { client, run in
                            let engine = LineupEngine(client: client, model: model.id)
                            let batting = try await engine.battingOrder(ctx)
                            let defense = try await engine.defense(ctx, battingOrder: batting.order)
                            run.lineup = EvalLineup(batting: batting, defense: defense, context: ctx)
                        }
                    }
                }
            } else {
                log("No game named \(gameName).")
            }
        }

        // Player assessments. A stored one from the same model on the same facts is reused for free.
        let wanted = (defaults.string(forKey: "PMEvalPlayers") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let players = team.activePlayers.filter { player in wanted.contains { player.name.lowercased() == $0 || player.name.lowercased().hasPrefix($0 + " ") } }
        results.addPlayers(players.map(\.snapshot))
        for player in players {
            let snapshot = player.snapshot
            let subject = snapshot.id.uuidString
            for model in models {
                if let stored = player.assessment, stored.model == model.id, stored.facts.fingerprint == FactSheet.player(snapshot).fingerprint,
                   !results.runs.contains(where: { $0.subject == subject && $0.model == model.id && $0.error == nil }) {
                    results.runs.removeAll { $0.subject == subject && $0.model == model.id }
                    results.runs.append(EvalRun(kind: "player", subject: subject, model: model.id, effort: stored.effort, reused: true, assessment: stored))
                    if results.blind[subject] == nil { results.blind[subject] = models.map(\.id).shuffled() }
                    log("player \(subject) · \(model.id): reused the stored assessment")
                    save()
                    continue
                }
                await attempt("player", subject, model) { client, run in
                    run.assessment = try await Scout(client: client, model: model.id, effort: run.effort).assess(snapshot, ageGroup: team.ageGroup)
                }
            }
        }

        save()
        let page = folder.appending(path: "grade.html")
        try? GradePage.html(results).write(to: page, atomically: true, encoding: .utf8)
        log(stopped ? "Stopped early. Relaunch later to finish; finished runs are kept." : "Done.")
        log("Grade: \(page.path)")
        NSWorkspace.shared.open(page)
    }

    static func pickModels(_ models: [ChatGPTClient.ModelInfo]) -> [ChatGPTClient.ModelInfo] {
        if let list = UserDefaults.standard.string(forKey: "PMEvalModels") {
            return list.split(separator: ",").compactMap { id in models.first { $0.id == id.trimmingCharacters(in: .whitespaces) } }
        }
        return families.compactMap { family in
            models.compactMap { model -> (ChatGPTClient.ModelInfo, [Int])? in
                guard let match = model.id.wholeMatch(of: /gpt-(\d+(?:\.\d+)*)-([a-z]+)/), match.2 == family else { return nil }
                return (model, match.1.split(separator: ".").compactMap { Int($0) })
            }
            .max { $0.1.lexicographicallyPrecedes($1.1) }?.0
        }
    }

    nonisolated static func log(_ message: String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard))  \(message)\n"
        print("Eval: " + message)
        let url = folder.appending(path: "progress.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Passes requests through and records how long each took and its tokens.
nonisolated final class RecordingClient: LLMClient, Sendable {
    let base: any LLMClient
    private let calls = Mutex<[EvalCall]>([])

    init(_ base: any LLMClient) { self.base = base }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let start = ContinuousClock.now
        let response = try await base.complete(request)
        let call = EvalCall(seconds: (ContinuousClock.now - start) / .seconds(1), inputTokens: response.usage.promptTokens, outputTokens: response.usage.completionTokens)
        calls.withLock { $0.append(call) }
        EvalRunner.log(String(format: "  call: %.0f s, %d in / %d out", call.seconds, call.inputTokens, call.outputTokens))
        return response
    }

    var recorded: [EvalCall] { calls.withLock { $0 } }
}

// MARK: - Results

nonisolated struct EvalResults: Codable {
    var effort: String
    var players: [EvalPlayer] = []
    var lineupCase: LineupCase?
    var runs: [EvalRun] = []
    /// Per subject, the models in a fixed shuffled order: the first is A, the next B, and so on.
    var blind: [String: [String]] = [:]

    mutating func addPlayers(_ snapshots: [PlayerSnapshot]) {
        for p in snapshots where !players.contains(where: { $0.id == p.id.uuidString }) {
            players.append(EvalPlayer(id: p.id.uuidString, name: p.name, jersey: p.jersey))
        }
    }
}

nonisolated struct EvalPlayer: Codable {
    var id: String
    var name: String
    var jersey: String?
}

nonisolated struct LineupCase: Codable {
    var game: String
    var ruleSet: String
    var rules: [String]
    var innings: Int
    var locks: [EvalLock]
    var absent: [String]
}

nonisolated struct EvalLock: Codable {
    var inning: Int
    var player: String
    var slot: String
}

nonisolated struct EvalCall: Codable {
    var seconds: Double
    var inputTokens: Int
    var outputTokens: Int
}

nonisolated struct EvalRun: Codable {
    var kind: String
    var subject: String
    var model: String
    var effort: String?
    var calls: [EvalCall] = []
    var error: String?
    var reused = false
    var lineup: EvalLineup?
    var assessment: PlayerAssessment?
}

nonisolated struct EvalLineup: Codable {
    struct Inning: Codable {
        var positions: [String: String]
        var sitting: [String]
    }
    struct Cell: Codable {
        var inning: Int
        var player: String
    }

    var battingOrder: [String]
    var battingReasons: [String: String]
    var battingRationale: String
    var innings: [Inning]
    var inningReasons: [String]
    var defenseRationale: String
    var warnings: [String]
    var battingRevisions: Int
    var defenseRevisions: Int
    var battingAdjusted: Bool
    var adjusted: [Cell]
    /// What the validator still finds in the final lineup (notes and warnings; violations only if the safety net failed).
    var findings: [String]

    init(batting: BattingResult, defense: DefenseResult, context: GameContext) {
        battingOrder = batting.order.map(\.uuidString)
        battingReasons = Dictionary(batting.reasons.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { a, _ in a })
        battingRationale = batting.rationale
        innings = defense.innings.map { inning in
            Inning(positions: Dictionary(inning.positions.map { ($0.key.rawValue, $0.value.uuidString) }, uniquingKeysWith: { a, _ in a }),
                   sitting: inning.sitting.map(\.uuidString))
        }
        inningReasons = defense.inningReasons
        defenseRationale = defense.rationale
        warnings = defense.warnings
        battingRevisions = batting.revisions
        defenseRevisions = defense.revisions
        battingAdjusted = batting.adjustedByApp
        adjusted = defense.adjustedCells.map { Cell(inning: $0.inning, player: $0.player.uuidString) }
        let lineup = Lineup(battingOrder: batting.order, innings: defense.innings)
        let defenseFindings = Validator.excusing(Validator.validateDefense(lineup, context: context), conflicts: Validator.lockConflicts(context))
        findings = (Validator.validateBattingOrder(batting.order, context: context) + defenseFindings)
            .map { "\($0.severity.rawValue): \($0.message)" }
    }
}
#endif
