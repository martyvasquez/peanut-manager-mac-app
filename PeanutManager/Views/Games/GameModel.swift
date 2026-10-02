import SwiftUI
import SwiftData
import LineupKit
import LineupAI

/// State and actions for one game's lineup. Every change is written straight back to the store
/// (v1 lost coach edits on reload) and registered with the window's undo manager.
@Observable
final class GameModel {
    let game: Game
    private(set) var document: LineupDocument
    var status: String?
    var errorMessage: String?
    var isGenerating: Bool { task != nil }
    private var task: Task<Void, Never>?

    init(game: Game) {
        self.game = game
        self.document = game.document ?? LineupDocument()
        normalize()
    }

    // MARK: - Derived

    @ObservationIgnored private var contextCache: (key: Int, value: GameContext)?
    @ObservationIgnored private var findingsCache: (key: Int, value: [Finding])?

    /// Built from the store only when something it depends on changed. Decoding every player on each
    /// redraw made clicks in the grid feel laggy.
    var context: GameContext {
        let key = contextKey
        if let cache = contextCache, cache.key == key { return cache.value }
        let value = game.context(locks: document.locks)
        contextCache = (key, value)
        return value
    }

    private var contextKey: Int {
        var h = Hasher()
        h.combine(game.innings); h.combine(game.priorityRaw); h.combine(game.weightingRaw)
        h.combine(game.notesForAI); h.combine(game.scoutingReport); h.combine(game.availabilityData)
        h.combine(game.team?.ageGroup)
        for rule in game.ruleSet?.sortedRules ?? [] {
            h.combine(rule.uid); h.combine(rule.text); h.combine(rule.enabled); h.combine(rule.checkData)
        }
        for player in game.team?.activePlayers ?? [] {
            h.combine(player.uid); h.combine(player.name); h.combine(player.jersey); h.combine(player.notes)
            h.combine(player.profileData); h.combine(player.ratingsData); h.combine(player.statsData)
        }
        h.combine(document.locks)
        return h.finalize()
    }
    var lineup: Lineup { document.lineup }
    var hasBattingOrder: Bool { !document.lineup.battingOrder.isEmpty }
    var hasDefense: Bool { document.lineup.hasDefense }

    /// Live validation — recomputed on every edit, never taken from the AI.
    var findings: [Finding] {
        var h = Hasher()
        h.combine(contextKey); h.combine(document.lineup)
        let key = h.finalize()
        if let cache = findingsCache, cache.key == key { return cache.value }
        let value = computeFindings()
        findingsCache = (key, value)
        return value
    }

    private func computeFindings() -> [Finding] {
        let ctx = context
        var result: [Finding] = []
        if hasBattingOrder { result += Validator.validateBattingOrder(document.lineup.battingOrder, context: ctx) }
        if hasDefense { result += Validator.validateDefense(document.lineup, context: ctx) }
        return result
    }

    /// Grid rows: the batting order, then anyone here who isn't in it yet, then anyone still on the grid who left.
    var rows: [PlayerSnapshot] {
        let ctx = context
        var seen = Set<PlayerID>()
        var ids = document.lineup.battingOrder.filter { seen.insert($0).inserted }
        ids += ctx.presentPlayers.map(\.id).filter { seen.insert($0).inserted }
        for inning in document.lineup.innings {
            ids += (Array(inning.positions.values) + inning.sitting).filter { seen.insert($0).inserted }
        }
        return ids.compactMap { ctx.player($0) }
    }

    func isLocked(_ cell: CellKey) -> Bool {
        document.locks.contains { $0.inning == cell.inning && $0.player == cell.player }
    }

    func isInningLocked(_ inning: Int) -> Bool {
        let available = context.availablePlayers(inning: inning)
        return !available.isEmpty && available.allSatisfy { isLocked(CellKey(inning: inning, player: $0.id)) }
    }

    // MARK: - Edits (undoable)

    func mutate(_ actionName: String, undoManager: UndoManager?, _ change: (inout LineupDocument) -> Void) {
        let before = document
        change(&document)
        guard document != before else { return }
        save()
        undoManager?.registerUndo(withTarget: self) { target in
            target.mutate(actionName, undoManager: undoManager) { $0 = before }
        }
        undoManager?.setActionName(actionName)
    }

    /// Coach picks a slot for a player: a true swap, and the chosen cell is locked so regeneration keeps it.
    func assign(_ player: PlayerID, to slot: Slot, inning: Int, undoManager: UndoManager?) {
        mutate("Change Position", undoManager: undoManager) { doc in
            let displaced: PlayerID? = if case .field(let position) = slot { doc.lineup.innings[inning - 1].positions[position] } else { nil }
            doc.lineup.assign(player, to: slot, inning: inning)
            doc.locks.removeAll { $0.inning == inning && ($0.player == player || $0.player == displaced) }
            doc.locks.append(Lock(inning: inning, player: player, slot: slot))
            doc.provenance[CellKey(inning: inning, player: player)] = .coach
            if let displaced { doc.provenance[CellKey(inning: inning, player: displaced)] = .coach }
        }
    }

    func toggleLock(_ cell: CellKey, undoManager: UndoManager?) {
        guard let slot = document.lineup.slot(of: cell.player, inning: cell.inning) else { return }
        mutate(isLocked(cell) ? "Unlock" : "Lock", undoManager: undoManager) { doc in
            if doc.locks.contains(where: { $0.inning == cell.inning && $0.player == cell.player }) {
                doc.locks.removeAll { $0.inning == cell.inning && $0.player == cell.player }
            } else {
                doc.locks.append(Lock(inning: cell.inning, player: cell.player, slot: slot))
            }
        }
    }

    func toggleInningLock(_ inning: Int, undoManager: UndoManager?) {
        let lock = !isInningLocked(inning)
        mutate(lock ? "Lock Inning" : "Unlock Inning", undoManager: undoManager) { doc in
            doc.locks.removeAll { $0.inning == inning }
            guard lock, doc.lineup.innings.indices.contains(inning - 1) else { return }
            let assignment = doc.lineup.innings[inning - 1]
            for (position, id) in assignment.positions { doc.locks.append(Lock(inning: inning, player: id, slot: .field(position))) }
            for id in assignment.sitting { doc.locks.append(Lock(inning: inning, player: id, slot: .bench)) }
        }
    }

    func moveBatter(_ player: PlayerID, by offset: Int, undoManager: UndoManager?) {
        mutate("Move in Batting Order", undoManager: undoManager) { doc in
            var order = doc.lineup.battingOrder
            for id in rows.map(\.id) where !order.contains(id) && context.availability(of: id).present { order.append(id) }
            guard let index = order.firstIndex(of: player) else { return }
            let target = min(max(index + offset, 0), order.count - 1)
            order.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
            doc.lineup.battingOrder = order
        }
    }

    func setInnings(_ innings: Int, undoManager: UndoManager?) {
        game.innings = innings
        mutate("Change Innings", undoManager: undoManager) { doc in
            if doc.lineup.hasDefense { doc.lineup.resize(innings: innings) }
            doc.locks.removeAll { $0.inning > innings }
        }
    }

    func startOver(undoManager: UndoManager?) {
        snapshot("Before Start Over")
        mutate("Start Over", undoManager: undoManager) { $0 = LineupDocument() }
    }

    func restore(_ version: LineupVersion, undoManager: UndoManager?) {
        snapshot("Before Restore")
        mutate("Restore Version", undoManager: undoManager) { $0 = version.document }
    }

    // MARK: - Generation

    var lineupModel: String {
        let stored = UserDefaults.standard.string(forKey: AppSettings.lineupModelKey) ?? ""
        return stored.isEmpty ? OpenRouterClient.defaultLineupModel : stored
    }

    /// One click: batting order, then defense.
    func generate(battingToo: Bool = true, feedback: String? = nil, undoManager: UndoManager?) {
        guard task == nil else { return }
        errorMessage = nil
        // Check the game can be lined up at all before spending anything on the AI.
        let feasibility = Validator.feasibility(context)
        if feasibility.hasViolations {
            errorMessage = feasibility.violations.map(\.message).joined(separator: "\n")
            return
        }
        var client: any LLMClient = OpenRouterClient(apiKey: Keychain.apiKey)
        #if DEBUG
        if DebugSupport.fakeAI { client = FakeLLMClient() }
        #endif
        let engine = LineupEngine(client: client, model: lineupModel)
        if hasBattingOrder || hasDefense { snapshot("Before Regenerate") }

        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.status = nil }
            do {
                let report: @Sendable (GenerationProgress) -> Void = { event in
                    Task { @MainActor in self.status = Self.describe(event) }
                }
                if battingToo || !hasBattingOrder {
                    let batting = try await engine.battingOrder(context, progress: report)
                    try Task.checkCancellation()
                    mutate("Generate Batting Order", undoManager: undoManager) { doc in
                        doc.lineup.battingOrder = batting.order
                        doc.battingReasons = batting.reasons
                        doc.battingRationale = batting.rationale
                        doc.cost = (doc.cost ?? 0) + (batting.usage.cost ?? 0)
                    }
                }
                let current = hasDefense ? document.lineup : nil
                let defense = try await engine.defense(context, battingOrder: document.lineup.battingOrder, currentLineup: current, feedback: feedback, progress: report)
                try Task.checkCancellation()
                mutate("Generate Lineup", undoManager: undoManager) { doc in
                    doc.lineup.innings = defense.innings
                    doc.provenance = defense.provenance
                    doc.inningReasons = defense.inningReasons
                    doc.defenseRationale = defense.rationale
                    doc.warnings = defense.warnings
                    doc.aiRuleNotes = defense.aiRuleNotes
                    doc.revisions = defense.revisions
                    doc.appAdjustedCount = defense.adjustedCells.count
                    doc.cost = (doc.cost ?? 0) + (defense.usage.cost ?? 0)
                    doc.model = engine.model
                    doc.generatedAt = .now
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        status = nil
    }

    nonisolated static func describe(_ event: GenerationProgress) -> String {
        switch event {
        case .asking(.battingOrder): "Building the batting order…"
        case .asking(.defense): "Setting the defense, inning by inning…"
        case .revising(let phase, let round, let problems): "Checking the \(phase.rawValue): fixing \(problems) problem\(problems == 1 ? "" : "s") (pass \(round))…"
        case .adjusting: "Making final adjustments…"
        }
    }

    // MARK: - Persistence

    private func save() {
        game.document = document
    }

    func snapshot(_ label: String) {
        guard document.lineup.hasDefense || !document.lineup.battingOrder.isEmpty else { return }
        var history = game.history
        history.append(LineupVersion(savedAt: .now, label: label, document: document))
        game.history = history
    }

    /// Keep the stored grid the right size if the game's innings changed elsewhere.
    private func normalize() {
        if document.lineup.hasDefense && document.lineup.innings.count != game.innings {
            document.lineup.resize(innings: game.innings)
        }
    }
}
