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
    /// The last failure was the ChatGPT plan's usage limit (offer Manage Usage).
    var usageLimitReached = false
    /// True when the lineup is blocked because nobody can play some position (fixable in the roster).
    var blockedByPositions = false
    var isGenerating: Bool { task != nil }
    private var task: Task<Void, Never>?

    init(game: Game) {
        self.game = game
        self.document = game.document ?? LineupDocument()
        normalize()
        step = hasGrid && hasBattingOrder ? .positions : .battingOrder
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
    /// The positions grid exists (it may be empty, or hold only the coach's locked spots).
    var hasGrid: Bool { game.innings > 0 && document.lineup.innings.count == game.innings }
    /// Every position is taken in every inning, or the AI has filled them at least once.
    var isFilled: Bool { hasGrid && (document.lineup.isFullyPositioned || (document.generatedAt != nil && hasDefense)) }

    /// Batters in order, here today. Anyone here who isn't in it yet is in `unplacedBatters`.
    var placedBatters: [PlayerID] {
        let ctx = context
        return document.lineup.battingOrder.filter { ctx.availability(of: $0).present }
    }

    var unplacedBatters: [PlayerSnapshot] {
        let placed = Set(document.lineup.battingOrder)
        return context.presentPlayers.filter { !placed.contains($0.id) }
    }

    /// Everyone here has a spot in the order.
    var isBattingOrderComplete: Bool { hasBattingOrder && unplacedBatters.isEmpty }

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
        // What the coach's own locks make unavoidable shows as a warning, not an AI mistake.
        if isFilled { result += Validator.excusing(Validator.validateDefense(document.lineup, context: ctx), conflicts: Validator.lockConflicts(ctx)) }
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

    /// `change` must only use its `doc` argument. Reading `document` (or anything derived from it, like
    /// `context` or `rows`) inside the closure is a Swift exclusivity violation and aborts the app.
    /// The game's inning count is undone with the lineup, since adding or removing an inning changes both.
    func mutate(_ actionName: String, undoManager: UndoManager?, _ change: (inout LineupDocument) -> Void) {
        let before = document
        let inningsBefore = game.innings
        change(&document)
        guard document != before || game.innings != inningsBefore else { return }
        save()
        undoManager?.registerUndo(withTarget: self) { target in
            // Mutate first so the redo it registers captures today's inning count, then put the old one back.
            target.mutate(actionName, undoManager: undoManager) { $0 = before }
            target.game.innings = inningsBefore
        }
        undoManager?.setActionName(actionName)
    }

    /// Coach picks a slot for a player: a true swap, and the chosen cell is locked so regeneration keeps it.
    /// Once the last position in an inning is taken, everyone else sits.
    func assign(_ player: PlayerID, to slot: Slot, inning: Int, undoManager: UndoManager?) {
        let available = context.availablePlayers(inning: inning).map(\.id)
        mutate("Change Position", undoManager: undoManager) { doc in
            let displaced: PlayerID? = if case .field(let position) = slot { doc.lineup.innings[inning - 1].positions[position] } else { nil }
            doc.lineup.assign(player, to: slot, inning: inning)
            doc.lineup.innings[inning - 1].seatRest(available: available)
            doc.locks.removeAll { $0.inning == inning && ($0.player == player || $0.player == displaced) }
            doc.locks.append(Lock(inning: inning, player: player, slot: slot))
            doc.provenance[CellKey(inning: inning, player: player)] = .coach
            if let displaced { doc.provenance[CellKey(inning: inning, player: displaced)] = .coach }
        }
    }

    /// Whether `a` and `b` can trade places this inning: both are available, and each can play where the other was.
    func canSwap(_ a: PlayerID, _ b: PlayerID, inning: Int) -> Bool {
        let ctx = context
        guard a != b, ctx.availability(of: a).isAvailable(inning: inning), ctx.availability(of: b).isAvailable(inning: inning) else { return false }
        func fits(_ id: PlayerID, _ slot: Slot?) -> Bool {
            guard case .field(let position) = slot else { return true }
            return ctx.player(id)?.profile.canPlay(position) ?? false
        }
        return fits(a, lineup.slot(of: b, inning: inning)) && fits(b, lineup.slot(of: a, inning: inning))
    }

    /// Dragging one kid's spot onto another's in the same inning: they trade places, and both become the coach's picks.
    func swap(_ a: PlayerID, _ b: PlayerID, inning: Int, undoManager: UndoManager?) {
        guard a != b, document.lineup.innings.indices.contains(inning - 1) else { return }
        let available = context.availablePlayers(inning: inning).map(\.id)
        mutate("Swap", undoManager: undoManager) { doc in
            doc.lineup.innings[inning - 1].swap(a, b)
            doc.lineup.innings[inning - 1].seatRest(available: available)
            doc.locks.removeAll { $0.inning == inning && ($0.player == a || $0.player == b) }
            for id in [a, b] {
                guard let slot = doc.lineup.slot(of: id, inning: inning) else { continue }
                doc.locks.append(Lock(inning: inning, player: id, slot: slot))
                doc.provenance[CellKey(inning: inning, player: id)] = .coach
            }
        }
    }

    // MARK: - Innings

    /// Adds an empty inning so it becomes inning `number`.
    /// The game's count changes inside `mutate` so undo puts both back.
    func insertInning(at number: Int, undoManager: UndoManager?) {
        let game = game
        mutate("Add Inning", undoManager: undoManager) { doc in
            doc.lineup.resize(innings: game.innings)
            Self.carry(&doc, along: doc.lineup.insertInning(at: number))
            game.innings += 1
        }
    }

    func removeInning(_ number: Int, undoManager: UndoManager?) {
        let game = game
        guard game.innings > 1 else { return }
        mutate("Delete Inning", undoManager: undoManager) { doc in
            doc.lineup.resize(innings: game.innings)
            Self.carry(&doc, along: doc.lineup.removeInning(number))
            game.innings -= 1
        }
    }

    func moveInning(_ from: Int, to: Int, undoManager: UndoManager?) {
        mutate("Move Inning", undoManager: undoManager) { doc in
            Self.carry(&doc, along: doc.lineup.moveInning(from, to: to))
        }
    }

    /// The inning the coach last copied. App-wide like the clipboard, so it pastes into any game.
    static var copiedInning: InningAssignment?

    func copyInning(_ number: Int) {
        Self.copiedInning = document.lineup.innings[safe: number - 1]
    }

    /// Replaces inning `number` with the copied one, for whoever's available then. What's pasted counts as the coach's picks.
    func pasteInning(into number: Int, undoManager: UndoManager?) {
        guard var pasted = Self.copiedInning, document.lineup.innings.indices.contains(number - 1) else { return }
        let available = context.availablePlayers(inning: number).map(\.id)
        for (position, id) in pasted.positions where !available.contains(id) { pasted.positions[position] = nil }
        pasted.sitting.removeAll { !available.contains($0) }
        pasted.seatRest(available: available)
        mutate("Paste Inning", undoManager: undoManager) { doc in
            doc.lineup.innings[number - 1] = pasted
            doc.locks.removeAll { $0.inning == number }
            doc.provenance = doc.provenance.filter { $0.key.inning != number }
            for (position, id) in pasted.positions { doc.locks.append(Lock(inning: number, player: id, slot: .field(position))) }
            for id in pasted.sitting { doc.locks.append(Lock(inning: number, player: id, slot: .bench)) }
            for lock in doc.locks where lock.inning == number { doc.provenance[CellKey(inning: number, player: lock.player)] = .coach }
        }
    }

    /// Locks, provenance and the AI's per-inning notes follow their inning when innings move.
    private static func carry(_ doc: inout LineupDocument, along map: Lineup.InningMap) {
        doc.locks = doc.locks.compactMap { lock in map(lock.inning).map { Lock(inning: $0, player: lock.player, slot: lock.slot) } }
        doc.provenance = Dictionary(doc.provenance.compactMap { key, value in map(key.inning).map { (CellKey(inning: $0, player: key.player), value) } }, uniquingKeysWith: { a, _ in a })
        var reasons = Array(repeating: "", count: doc.lineup.innings.count)
        for (index, reason) in doc.inningReasons.enumerated() {
            if let to = map(index + 1), reasons.indices.contains(to - 1) { reasons[to - 1] = reason }
        }
        doc.inningReasons = doc.inningReasons.isEmpty ? [] : reasons
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

    /// The full batting order: the saved order plus anyone here who isn't in it yet.
    /// Computed *before* `mutate`: reading `document` inside a mutate closure is an exclusivity
    /// violation (the document is already being written) and crashes the app.
    private func fullBattingOrder() -> [PlayerID] {
        let ctx = context
        var order = document.lineup.battingOrder
        for id in rows.map(\.id) where !order.contains(id) && ctx.availability(of: id).present { order.append(id) }
        return order.filter { ctx.availability(of: $0).present }
    }

    func moveBatter(_ player: PlayerID, by offset: Int, undoManager: UndoManager?) {
        var order = fullBattingOrder()
        guard let index = order.firstIndex(of: player) else { return }
        let target = min(max(index + offset, 0), order.count - 1)
        order.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        mutate("Move in Batting Order", undoManager: undoManager) { $0.lineup.battingOrder = order }
    }

    /// Opens step 2 with an empty grid so the coach can lock spots before the AI fills the rest.
    func preparePositions() {
        if !hasGrid {
            document.lineup.resize(innings: game.innings)
            save()
        }
        step = .positions
    }

    /// Back to an empty grid, keeping the batting order.
    func clearPositions(undoManager: UndoManager?) {
        snapshot("Before Clear Positions")
        mutate("Clear Positions", undoManager: undoManager) { doc in
            doc.lineup.innings = Array(repeating: InningAssignment(), count: game.innings)
            doc.locks = []
            doc.provenance = [:]
            doc.inningReasons = []
            doc.defenseRationale = ""
            doc.warnings = []
            doc.aiRuleNotes = []
            doc.revisions = 0
            doc.appAdjustedCount = 0
            doc.generatedAt = nil
        }
        step = .positions
    }

    /// The batting order step's spots, one per kid here; empty ones are nil.
    var battingSlots: [PlayerID?] {
        BattingSlots.resolve(document.battingSlots, order: document.lineup.battingOrder, present: context.presentPlayers.map(\.id))
    }

    /// Puts `player` in spot `index` (0-based), or the first empty spot. A taken spot makes room (`BattingSlots.place`).
    func placeBatter(_ player: PlayerID, inSlot index: Int?, undoManager: UndoManager?) {
        let before = battingSlots
        let after = BattingSlots.place(player, at: index, in: before)
        guard after != before else { return }
        saveSlots(after, before.contains(player) ? "Move in Batting Order" : "Add to Batting Order", undoManager: undoManager)
    }

    func removeBatter(_ player: PlayerID, undoManager: UndoManager?) {
        var slots = battingSlots
        guard let index = slots.firstIndex(of: player) else { return }
        slots[index] = nil
        saveSlots(slots, "Remove from Batting Order", undoManager: undoManager)
    }

    private func saveSlots(_ slots: [PlayerID?], _ actionName: String, undoManager: UndoManager?) {
        mutate(actionName, undoManager: undoManager) { doc in
            doc.lineup.battingOrder = slots.compactMap { $0 }
            doc.battingSlots = slots.contains(nil) ? slots : nil
        }
    }

    // MARK: - Copy

    /// Other games with a lineup, most recent first.
    var copySources: [Game] {
        (game.team?.games ?? [])
            .filter { $0 !== game && !($0.document?.lineup.battingOrder.isEmpty ?? true) }
            .sorted { $0.date > $1.date }
    }

    /// The most recent game before this one, or the most recent one if none came before.
    var lastGame: Game? {
        let sources = copySources
        return sources.first { $0.date < game.date } ?? sources.first
    }

    /// Starts from another game's lineup. What's copied counts as the coach's own picks, so it's locked.
    func copyLineup(from source: Game, undoManager: UndoManager?) {
        guard let lineup = source.document?.lineup else { return }
        let ctx = context
        let copied = lineup.carriedOver(
            innings: game.innings,
            present: Set(ctx.presentPlayers.map(\.id)),
            available: { ctx.availablePlayers(inning: $0).map(\.id) }
        )
        var locks: [Lock] = []
        for (index, inning) in copied.innings.enumerated() {
            for (position, id) in inning.positions { locks.append(Lock(inning: index + 1, player: id, slot: .field(position))) }
            // A kid who wasn't at that game sits because the inning is full, not because the coach said so.
            let sat = lineup.innings.indices.contains(index) ? lineup.innings[index].sitting : []
            for id in inning.sitting where sat.contains(id) { locks.append(Lock(inning: index + 1, player: id, slot: .bench)) }
        }
        snapshot("Before Copy")
        mutate("Copy Lineup", undoManager: undoManager) { doc in
            doc = LineupDocument()
            doc.lineup = copied
            doc.locks = locks
            for lock in locks { doc.provenance[CellKey(inning: lock.inning, player: lock.player)] = .coach }
        }
        step = hasGrid && isBattingOrderComplete ? .positions : .battingOrder
    }

    /// Drag and drop: moving down lands below `target`, moving up lands above it.
    func moveBatter(_ player: PlayerID, to target: PlayerID, undoManager: UndoManager?) {
        var order = fullBattingOrder()
        guard let from = order.firstIndex(of: player), let to = order.firstIndex(of: target), from != to else { return }
        order.remove(at: from)
        order.insert(player, at: to)
        mutate("Move in Batting Order", undoManager: undoManager) { $0.lineup.battingOrder = order }
    }

    func startOver(undoManager: UndoManager?) {
        snapshot("Before Start Over")
        mutate("Clear Lineup", undoManager: undoManager) { $0 = LineupDocument() }
        step = .battingOrder
    }

    func restore(_ version: LineupVersion, undoManager: UndoManager?) {
        snapshot("Before Restore")
        mutate("Restore Version", undoManager: undoManager) { $0 = version.document }
    }

    // MARK: - Generation

    var lineupModel: String { AIService.shared.currentModelID }

    enum Step { case battingOrder, positions }

    /// Which step the coach is looking at. Positions once a defense exists, unless they go back.
    var step: Step = .battingOrder
    /// What's being generated right now, so the view can show progress in the right place.
    private(set) var generating: Step?

    /// Step 1: the AI proposes a batting order. With feedback, it adjusts the current one.
    func makeBattingOrder(feedback: String? = nil, undoManager: UndoManager?) {
        run(.battingOrder, undoManager: undoManager) { engine, report in
            let current = self.hasBattingOrder ? self.document.lineup.battingOrder : nil
            let batting = try await engine.battingOrder(self.context, currentOrder: current, feedback: feedback, progress: report)
            try Task.checkCancellation()
            let effort = self.effort
            self.mutate("Make Batting Order", undoManager: undoManager) { doc in
                doc.lineup.battingOrder = batting.order
                doc.battingReasons = batting.reasons
                doc.battingRationale = batting.rationale
                doc.cost = (doc.cost ?? 0) + (batting.usage.cost ?? 0)
                doc.model = engine.model
                doc.effort = effort
            }
            self.step = .battingOrder
        }
    }

    /// Locked spots that break a rule (or can't all be kept), waiting for the coach to fill anyway or cancel.
    var pendingConflicts: [Finding] = []
    /// The thinking level of the run in progress, saved with what it makes.
    @ObservationIgnored private var effort: String?
    @ObservationIgnored private var pendingFeedback: String?

    /// Step 2: the AI fills every inning around the batting order. Locked spots stay put.
    /// When the locks themselves break a rule, the coach decides first (`fillAnyway`).
    func setPositions(feedback: String? = nil, undoManager: UndoManager?, fillAnyway: Bool = false) {
        if !fillAnyway, task == nil {
            let conflicts = Validator.lockConflicts(context)
            if !conflicts.isEmpty {
                pendingFeedback = feedback
                pendingConflicts = conflicts
                return
            }
        }
        pendingConflicts = []
        run(.positions, undoManager: undoManager) { engine, report in
            let current = self.isFilled ? self.document.lineup : nil
            let defense = try await engine.defense(self.context, battingOrder: self.document.lineup.battingOrder, currentLineup: current, feedback: feedback, progress: report)
            try Task.checkCancellation()
            let effort = self.effort
            self.mutate("Set Positions", undoManager: undoManager) { doc in
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
                doc.effort = effort
                doc.generatedAt = .now
            }
            self.step = .positions
        }
    }

    /// The coach chose to keep the conflicting locks.
    func fillAnyway(undoManager: UndoManager?) {
        setPositions(feedback: pendingFeedback, undoManager: undoManager, fillAnyway: true)
        pendingFeedback = nil
    }

    private func run(_ step: Step, undoManager: UndoManager?, _ work: @escaping (LineupEngine, @escaping @Sendable (GenerationProgress) -> Void) async throws -> Void) {
        guard task == nil else { return }
        errorMessage = nil
        // Check the game can be lined up at all before spending anything on the AI.
        let feasibility = Validator.feasibility(context)
        if feasibility.hasViolations {
            blockedByPositions = feasibility.contains { $0.position != nil }
            errorMessage = feasibility.violations.map(\.message).joined(separator: "\n")
            return
        }
        blockedByPositions = false
        let ai = AIService.shared.client()
        let engine = LineupEngine(client: ai.client, model: ai.model)
        effort = ai.effort
        if hasBattingOrder || hasDefense { snapshot("Before Remake") }
        generating = step

        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.status = nil; self.generating = nil }
            do {
                let report: @Sendable (GenerationProgress) -> Void = { event in
                    Task { @MainActor in self.status = Self.describe(event) }
                }
                try await work(engine, report)
            } catch is CancellationError {
            } catch {
                usageLimitReached = AIService.isUsageLimit(error)
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
        case .asking(.battingOrder): "Working out the batting order…"
        case .asking(.defense): "Setting positions, inning by inning…"
        case .revising(_, _, let problems): "Fixing \(problems) rule problem\(problems == 1 ? "" : "s")…"
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
