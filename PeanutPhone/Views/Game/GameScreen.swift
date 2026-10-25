import SwiftUI
import SwiftData
import LineupKit
import LineupAI

/// One game, in the night-before order: the batting order, then positions. The AI is an extra button on each
/// step, never a gate: without it the coach builds both by hand.
struct GameScreen: View {
    @State private var model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var feedbackFor: GameModel.Step?
    /// What the coach asked for in Remake…, run once that sheet has closed so the next sheet (consent) can open.
    @State private var remake: (step: GameModel.Step, feedback: String)?
    @State private var confirmClear = false

    init(game: Game) {
        _model = State(initialValue: GameModel(game: game))
    }

    var body: some View {
        Group {
            switch model.step {
            case .battingOrder:
                BattingOrderList(model: model)
                    .safeAreaInset(edge: .bottom) { battingAction }
            case .positions:
                PositionsBoard(model: model) { model.setPositions(undoManager: undoManager) }
            }
        }
        .navigationTitle(model.game.opponent.isEmpty ? "Game" : model.game.opponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $feedbackFor, onDismiss: runRemake) { step in
            FeedbackSheet(prompt: step == .battingOrder ? "Bat Mia leadoff" : "Move Jake to the outfield") { feedback in
                remake = (step, feedback)
            }
        }
        .alert(model.blockedByPositions ? "Who Pitches and Catches?" : "Couldn't Make a Lineup",
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.usageLimitReached {
                Link("Manage Usage", destination: ChatGPTAuth.manageUsageURL)
            }
            Button("OK") {}
        } message: {
            Text(model.blockedByPositions
                 ? (model.errorMessage ?? "") + "\n\nTurn on P and C for those players in the roster."
                 : model.errorMessage ?? "")
        }
        // A lock that breaks a rule goes to the coach, never to the AI.
        .alert(model.pendingConflicts.count == 1 ? "A Locked Spot Breaks a Rule" : "Locked Spots Break Rules",
               isPresented: Binding(get: { !model.pendingConflicts.isEmpty }, set: { if !$0 { model.pendingConflicts = [] } })) {
            Button("Fill Anyway") { model.fillAnyway(undoManager: undoManager) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.pendingConflicts.map(\.message).joined(separator: "\n\n") + "\n\nUnlock a spot, or fill anyway and keep your locks.")
        }
        .confirmationDialog("Clear this lineup?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Lineup", role: .destructive) { model.startOver(undoManager: undoManager) }
        }
        .onAppear(perform: debugSetup)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Step", selection: Binding(
                get: { model.step },
                set: { step in
                    if step == .positions { model.preparePositions() } else { model.step = step }
                }
            )) {
                Text("Batting").tag(GameModel.Step.battingOrder)
                Text("Positions").tag(GameModel.Step.positions)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .disabled(model.isGenerating)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                    .disabled(!canUndo(after: model.document))
                if AIService.shared.isReady && !model.isGenerating {
                    if model.step == .battingOrder && model.isBattingOrderComplete {
                        Button("Remake Batting Order…", systemImage: "sparkles") { feedbackFor = .battingOrder }
                    }
                    if model.step == .positions && model.isFilled {
                        Button("Remake Positions…", systemImage: "sparkles") { feedbackFor = .positions }
                    }
                }
                Divider()
                if model.step == .positions && model.hasDefense {
                    Button("Clear Positions", systemImage: "eraser") { model.clearPositions(undoManager: undoManager) }
                }
                if model.hasBattingOrder || model.hasDefense {
                    Button("Clear Lineup…", systemImage: "trash", role: .destructive) { confirmClear = true }
                }
            }
        }
    }

    /// The one next thing to do on the batting step.
    @ViewBuilder
    private var battingAction: some View {
        if model.isGenerating {
            Progress(status: model.status) { model.cancel() }
                .padding(.bottom, 8)
        } else if model.isBattingOrderComplete {
            BottomButton(title: "Positions", systemImage: "arrow.right") { model.preparePositions() }
        } else if AIService.shared.isReady && !model.hasBattingOrder {
            BottomButton(title: "Make Batting Order", systemImage: "sparkles") { model.makeBattingOrder(undoManager: undoManager) }
        }
    }

    private func runRemake() {
        guard let remake else { return }
        self.remake = nil
        switch remake.step {
        case .battingOrder: model.makeBattingOrder(feedback: remake.feedback, undoManager: undoManager)
        case .positions: model.setPositions(feedback: remake.feedback, undoManager: undoManager)
        }
    }

    /// Takes the document so the button checks again after every edit (UndoManager isn't observable).
    private func canUndo(after _: LineupDocument) -> Bool { undoManager?.canUndo ?? false }

    private func debugSetup() {
        #if DEBUG
        let defaults = UserDefaults.standard
        // `-PMInnings 9` adds innings to the game (a test library only), each a copy of the inning six before it,
        // to try long games.
        let innings = defaults.integer(forKey: "PMInnings")
        while innings > model.game.innings {
            let added = model.game.innings + 1
            model.insertInning(at: added, undoManager: nil)
            model.copyInning(max(added - 6, 1))
            model.pasteInning(into: added, undoManager: nil)
        }
        switch defaults.string(forKey: "PMStep") {
        case "batting": model.step = .battingOrder
        case "positions": model.preparePositions()
        default: break
        }
        // `-PMClear positions|lineup` starts from an empty grid or an empty game.
        switch defaults.string(forKey: "PMClear") {
        case "positions": model.clearPositions(undoManager: nil)
        case "lineup": model.startOver(undoManager: nil)
        default: break
        }
        // `-PMLockDemo YES` places two spots by hand, the way a coach locks before Fill the Rest.
        if defaults.bool(forKey: "PMLockDemo"), model.hasGrid, model.rows.count > 4 {
            model.assign(model.rows[1].id, to: .field(.p), inning: 1, undoManager: nil)
            model.assign(model.rows[4].id, to: .field(.ss), inning: 1, undoManager: nil)
        }
        // `-PMFill YES` presses Fill the Rest (with -PMFakeAI, no AI company is involved).
        if defaults.bool(forKey: "PMFill"), model.hasGrid { model.setPositions(undoManager: nil) }
        #endif
    }
}

/// A prominent action pinned to the bottom of a list.
struct BottomButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

/// What the AI is doing right now, with a way out.
struct Progress: View {
    let status: String?
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(status ?? "Thinking…").foregroundStyle(.secondary).lineLimit(1)
            Button("Cancel", action: cancel)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .padding(.horizontal, 20)
    }
}

/// Tell the AI what to change: "Move Jake to the outfield." Locked spots stay.
struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    var prompt: String
    var onSubmit: (String) -> Void
    @State private var feedback = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextField("What should change?", text: $feedback, prompt: Text(prompt), axis: .vertical)
                .font(.title3)
                .lineLimit(3...8)
                .focused($focused)
                .padding(20)
                .frame(maxHeight: .infinity, alignment: .top)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Remake") {
                            onSubmit(feedback)
                            dismiss()
                        }
                    }
                }
                .navigationTitle("Remake")
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}

extension GameModel.Step: Identifiable {
    var id: Self { self }
}

/// Step 1: kids in batting order. Drag to reorder, swipe to take a kid out, tap a kid below to add them.
struct BattingOrderList: View {
    let model: GameModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let slots = model.battingSlots
        let unplaced = model.unplacedBatters
        // Spots up to the last kid placed; trailing empty spots would push the kids to add off the screen.
        let shown = slots.prefix((slots.lastIndex { $0 != nil } ?? -1) + 1)
        List {
            Section {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, id in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.body.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: 24, alignment: .trailing)
                        if let id, let player = model.context.player(id) {
                            Text(player.name)
                        } else {
                            Text("Empty").foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        if let id {
                            Button("Remove", role: .destructive) { model.removeBatter(id, undoManager: undoManager) }
                        }
                    }
                    .moveDisabled(id == nil)
                }
                .onMove { from, to in
                    guard let source = from.first, let id = slots[source] else { return }
                    withAnimation { model.placeBatter(id, inSlot: to > source ? to - 1 : to, undoManager: undoManager) }
                }
            }
            if !unplaced.isEmpty {
                Section("Tap to Add") {
                    ForEach(unplaced) { player in
                        Button {
                            withAnimation { model.placeBatter(player.id, inSlot: nil, undoManager: undoManager) }
                        } label: {
                            Label {
                                Text(player.name).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "plus.circle.fill")
                            }
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .disabled(model.isGenerating)
    }
}
