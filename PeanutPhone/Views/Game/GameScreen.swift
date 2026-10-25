import SwiftUI
import SwiftData
import LineupKit
import LineupAI
import UIKit

/// One game, in the night-before order: the batting order, then positions. The AI is an extra button on each
/// step, never a gate: without it the coach builds both by hand.
struct GameScreen: View {
    @State private var model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var feedbackFor: GameModel.Step?
    /// What the coach asked for in Remake…, run once that sheet has closed so the next sheet (consent) can open.
    @State private var remake: (step: GameModel.Step, feedback: String)?
    @State private var confirmClear = false
    /// An AI action pressed before AI is set up: Settings opens with what it would do.
    @State private var setUpFor: AIFeature?
    @State private var showsSetup = false
    @Environment(\.scenePhase) private var scenePhase
    /// The last AI run the coach started, so one iOS cut off can start again.
    @State private var lastRun: Run?
    /// The app went to the background mid-run; if the run didn't survive, it starts again on return.
    @State private var interrupted = false
    @State private var backgroundTime: UIBackgroundTaskIdentifier = .invalid

    struct Run {
        var step: GameModel.Step
        var feedback: String?
        var fillAnyway = false
    }

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
                PositionsBoard(model: model) {
                    if AIService.shared.isReady { start(Run(step: .positions)) } else { setUpFor = .positions }
                }
            }
        }
        .navigationTitle(model.game.opponent.isEmpty ? "Game" : model.game.opponent)
        .navigationBarTitleDisplayMode(.inline)
        // The grid needs every point; the tabs come back on the way out.
        .toolbar(.hidden, for: .tabBar)
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
            Button("Fill Anyway") { start(Run(step: .positions, feedback: lastRun?.feedback, fillAnyway: true)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.pendingConflicts.map(\.message).joined(separator: "\n\n") + "\n\nUnlock a spot, or fill anyway and keep your locks.")
        }
        .sheet(item: $setUpFor) { SettingsScreen(feature: $0) }
        .sheet(isPresented: $showsSetup) { GameSetupSheet(game: model.game, model: model) }
        .confirmationDialog("Clear this lineup?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Lineup", role: .destructive) { model.startOver(undoManager: undoManager) }
        }
        .onChange(of: model.isGenerating) { _, on in generatingChanged(on) }
        .onChange(of: scenePhase) { _, phase in phaseChanged(phase) }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
        // The night-before path ends here: print the card, or send it.
        if model.isFilled && !model.isGenerating {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Share", systemImage: "square.and.arrow.up") {
                    Button("Print…", systemImage: "printer") { LineupExport.print(model) }
                    Button("Send Lineup Card…", systemImage: "doc.richtext") { LineupExport.sharePDF(model) }
                    Button("Send as Text…", systemImage: "text.bubble") { LineupExport.shareText(model) }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                Button("Game Setup…", systemImage: "slider.horizontal.3") { showsSetup = true }
                Divider()
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
                if !model.copySources.isEmpty {
                    Menu("Copy Lineup From", systemImage: "doc.on.doc") {
                        ForEach(model.copySources) { source in
                            Button(Self.label(source)) { model.copyLineup(from: source, undoManager: undoManager) }
                        }
                    }
                }
                let history = model.game.history
                if !history.isEmpty {
                    Menu("Versions", systemImage: "clock.arrow.circlepath") {
                        ForEach(history.reversed()) { version in
                            Button(version.savedAt.formatted(date: .abbreviated, time: .shortened)) {
                                model.restore(version, undoManager: undoManager)
                            }
                        }
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
        } else if !model.hasBattingOrder {
            VStack(spacing: 4) {
                // A previous game's lineup as a starting point; copied spots count as the coach's picks.
                if !model.hasDefense, let last = model.lastGame {
                    Button("Copy \(Self.label(last))", systemImage: "doc.on.doc") { model.copyLineup(from: last, undoManager: undoManager) }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 36)
                }
                if AIService.shared.isReady {
                    BottomButton(title: "Make Batting Order", systemImage: "sparkles") { start(Run(step: .battingOrder)) }
                } else {
                    BottomButton(title: "Make Batting Order", systemImage: "sparkles", prominent: false) { setUpFor = .battingOrder }
                }
            }
        }
    }

    static func label(_ game: Game) -> String {
        "\(game.opponent) · \(game.date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func runRemake() {
        guard let remake else { return }
        self.remake = nil
        switch remake.step {
        case .battingOrder: start(Run(step: .battingOrder, feedback: remake.feedback))
        case .positions: start(Run(step: .positions, feedback: remake.feedback))
        }
    }

    private func start(_ run: Run) {
        lastRun = run
        switch run.step {
        case .battingOrder: model.makeBattingOrder(feedback: run.feedback, undoManager: undoManager)
        case .positions: model.setPositions(feedback: run.feedback, undoManager: undoManager, fillAnyway: run.fillAnyway)
        }
    }

    // MARK: - Runs that outlast the screen

    /// A run takes a minute or two, longer than auto-lock, and iOS drops a locked app's connection. So the screen
    /// stays awake while the AI works, iOS is asked for extra time if the coach leaves anyway, and a run cut off
    /// in the background starts again when they come back.
    private func generatingChanged(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
        if on {
            backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Lineup") { endBackgroundTime() }
        } else {
            endBackgroundTime()
            if scenePhase == .active { resumeIfCutOff() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    private func phaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background: if model.isGenerating { interrupted = true }
        case .active: resumeIfCutOff()
        default: break
        }
    }

    /// Back in front after leaving mid-run. Still running or finished in the extra time: nothing to do (a run still
    /// going comes back here when it ends). Ended in an error: start it again, once.
    private func resumeIfCutOff() {
        guard interrupted, !model.isGenerating else { return }
        interrupted = false
        guard model.errorMessage != nil, !model.usageLimitReached, !model.blockedByPositions, let run = lastRun else { return }
        model.errorMessage = nil
        start(run)
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
        // `-PMExport YES` writes the lineup card and text to Documents, to check them.
        if defaults.bool(forKey: "PMExport"), model.isFilled {
            let folder = URL.documentsDirectory
            try? LineupExport.pdf(model)?.write(to: folder.appending(path: "lineup.pdf"))
            try? LineupExport.text(model).write(to: folder.appending(path: "lineup.txt"), atomically: true, encoding: .utf8)
        }
        // `-PMGameSetup YES` opens the game's setup.
        if defaults.bool(forKey: "PMGameSetup") { showsSetup = true }
        // `-PMSetUp positions|battingOrder` opens Settings for that AI feature.
        if let feature = defaults.string(forKey: "PMSetUp").flatMap(AIFeature.init(rawValue:)) { setUpFor = feature }
        // `-PMFill YES` presses Fill the Rest (with -PMFakeAI, no AI company is involved).
        if defaults.bool(forKey: "PMFill"), model.hasGrid { start(Run(step: .positions)) }
        #endif
    }
}

/// A prominent action pinned to the bottom of a list.
struct BottomButton: View {
    let title: String
    let systemImage: String
    /// Filled for the next step; outlined for an AI action that needs setting up first.
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
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
    /// Tap a kid in the order for their card.
    @State private var cardPlayer: PlayerSnapshot?

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
                            Button(player.name) { cardPlayer = player }
                                .foregroundStyle(Color.primary)
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
                            // Explicit colors: a list button tints everything in it.
                            Label {
                                Text(player.name).foregroundStyle(Color.primary)
                            } icon: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .disabled(model.isGenerating)
        .sheet(item: $cardPlayer) { PlayerSheet(model: model, player: $0, focus: .batting) }
    }
}

/// Picks a button style at run time.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some PrimitiveButtonStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
