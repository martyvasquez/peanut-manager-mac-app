import SwiftUI
import SwiftData
import LineupKit
import LineupAI

struct GamesListView: View {
    @Environment(\.modelContext) private var context
    let team: Team
    @Binding var selection: Game?
    @State private var showingNewGame = false
    @State private var importing = false

    var body: some View {
        let games = team.games.sorted { $0.date < $1.date }
        let upcoming = games.filter { !$0.isPast }
        let past = Array(games.filter(\.isPast).reversed())

        List(selection: $selection) {
            if !upcoming.isEmpty {
                Section("Upcoming") { ForEach(upcoming) { GameRow(game: $0).tag($0) } }
            }
            if !past.isEmpty {
                Section("Past") { ForEach(past) { GameRow(game: $0).tag($0) } }
            }
        }
        .navigationTitle("Games")
        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        .overlay {
            // A game needs kids: no roster, no new games (games made earlier stay listed).
            if team.activePlayers.isEmpty && games.isEmpty {
                ContentUnavailableView {
                    Label("No Players Yet", systemImage: "person.3")
                } description: {
                    Text("Add your team first.")
                } actions: {
                    VStack(spacing: 8) {
                        Button("Import from GameChanger…") { importing = true }
                            .buttonStyle(.borderedProminent)
                        Button("Open Roster") { Navigator.shared.section = .roster }
                    }
                }
            } else if games.isEmpty {
                ContentUnavailableView {
                    Label("No Games", systemImage: "calendar")
                } actions: {
                    Button("New Game") { showingNewGame = true }
                }
            }
        }
        .toolbar {
            Button("New Game", systemImage: "plus") { showingNewGame = true }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(team.activePlayers.isEmpty)
                .help(team.activePlayers.isEmpty ? "Add players to the roster first" : "New Game")
        }
        .sheet(isPresented: $showingNewGame) {
            NewGameSheet(team: team) { selection = $0 }
        }
        .gameChangerImport(team: team, isPresented: $importing)
        .contextMenu(forSelectionType: Game.self) { games in
            if let game = games.first {
                Button("Delete", role: .destructive) {
                    if selection == game { selection = nil }
                    context.delete(game)
                }
            }
        }
    }
}

struct GameRow: View {
    let game: Game

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.opponent)
                Text(game.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let lineup = game.document?.lineup, lineup.hasDefense, lineup.isFullyPositioned || game.document?.generatedAt != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NewGameSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let team: Team
    var onCreate: (Game) -> Void
    @State private var opponent = ""
    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: .now)!

    var body: some View {
        Form {
            TextField("Opponent", text: $opponent)
            DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(opponent.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Everything else carries over from the last game, so the common path is one click.
    private func add() {
        let last = team.games.max { $0.date < $1.date }
        let game = Game(opponent: opponent.trimmingCharacters(in: .whitespaces), date: date, innings: last?.innings ?? team.defaultInnings)
        context.insert(game)
        game.team = team
        game.ruleSet = last?.ruleSet ?? team.sortedRuleSets.first
        if let last {
            game.priority = last.priority
            game.weighting = last.weighting
        }
        // Scouting notes on an opponent carry over to the next game against them.
        let name = game.opponent.lowercased()
        if let previous = team.games.filter({ $0 !== game && $0.opponent.lowercased() == name && !$0.scoutingReport.isEmpty }).max(by: { $0.date < $1.date }) {
            game.scoutingReport = previous.scoutingReport
        }
        onCreate(game)
        dismiss()
    }
}

// MARK: - Game

struct GameDetailView: View {
    @Bindable var game: Game
    @State private var model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var feedbackFor: GameModel.Step?
    /// What the coach asked for in Remake…, run once that sheet has closed so the next sheet (consent) can open.
    @State private var remake: (step: GameModel.Step, feedback: String)?
    @State private var confirmStartOver = false
    @State private var importingStats = false

    init(game: Game) {
        self.game = game
        _model = State(initialValue: GameModel(game: game))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    VStack(alignment: .leading, spacing: 18) {
                        stepBar
                        stepContent
                    }
                }
                .animation(.snappy, value: model.step)
                .animation(.snappy, value: model.hasBattingOrder)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if DEBUG
            .onChange(of: model.isFilled) {
                if DebugSupport.scrollToChecks {
                    Task { try? await Task.sleep(for: .milliseconds(300)); withAnimation { proxy.scrollTo("summary", anchor: .bottom) } }
                }
            }
            #endif
        }
        .toolbar { toolbar }
        .gameChangerImport(team: game.team, isPresented: $importingStats)
        .sheet(item: $feedbackFor, onDismiss: runRemake) { step in
            FeedbackSheet(prompt: step == .battingOrder ? "Bat Mia leadoff" : "Move Jake to the outfield") { feedback in
                remake = (step, feedback)
            }
        }
        .alert(model.blockedByPositions ? "Who Pitches and Catches?" : "Couldn't Make a Lineup", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.blockedByPositions {
                if canUseHistory {
                    Button("Use GameChanger History") { useHistoryAndRetry() }
                }
                Button("Open Roster") { Navigator.shared.section = .roster }
                Button("Cancel", role: .cancel) {}
            } else {
                if model.usageLimitReached {
                    Link("Manage Usage", destination: ChatGPTAuth.manageUsageURL)
                } else if !AIService.shared.isReady {
                    Button("Sign In with ChatGPT") { AIService.shared.signIn() }
                } else if model.errorMessage?.contains("Settings") == true {
                    SettingsLink { Text("Open Settings") }
                }
                Button("OK") {}
            }
        } message: {
            if model.blockedByPositions {
                Text(model.errorMessage.map { $0 + (canUseHistory ? "\n\nTurn on P and C from who pitched and caught in GameChanger, or set them in the roster." : "\n\nTurn on P and C for those players in the roster.") } ?? "")
            } else {
                Text(model.errorMessage ?? "")
            }
        }
        .alert(model.pendingConflicts.count == 1 ? "A Locked Spot Breaks a Rule" : "Locked Spots Break Rules", isPresented: Binding(get: { !model.pendingConflicts.isEmpty }, set: { if !$0 { model.pendingConflicts = [] } })) {
            Button("Fill Anyway") { model.fillAnyway(undoManager: undoManager) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.pendingConflicts.map(\.message).joined(separator: "\n\n") + "\n\nUnlock a spot, or fill anyway and keep your locks.")
        }
        .confirmationDialog("Clear this lineup?", isPresented: $confirmStartOver) {
            Button("Clear Lineup", role: .destructive) { model.startOver(undoManager: undoManager) }
        } message: {
            Text("You can undo, or restore it from Versions.")
        }
        .task {
            #if DEBUG
            // Only the first game opened after launch, so a game made while testing starts empty.
            guard DebugSupport.autoFills(game) else { return }
            if DebugSupport.copyLastGame && !model.hasBattingOrder, let last = model.lastGame { model.copyLineup(from: last, undoManager: undoManager) }
            if DebugSupport.autoGenerate && !model.hasBattingOrder { model.makeBattingOrder(undoManager: undoManager) }
            if DebugSupport.autoRemake && model.hasBattingOrder { feedbackFor = .battingOrder }
            if DebugSupport.autoPositions && model.hasBattingOrder && !model.isFilled { model.setPositions(undoManager: undoManager) }
            #endif
        }
        #if DEBUG
        .onChange(of: model.isFilled) {
            if model.isFilled && UserDefaults.standard.string(forKey: "PMPrintTo") != nil { LineupCardPrinter.print(model: model) }
        }
        .onChange(of: model.hasBattingOrder) {
            if DebugSupport.autoPositions && DebugSupport.autoFills(game) && model.hasBattingOrder && !model.isFilled { model.setPositions(undoManager: undoManager) }
            if UserDefaults.standard.bool(forKey: "PMOpenPositions") && model.hasBattingOrder {
                model.preparePositions()
                // Lock one spot the way a coach would, to show the state before Fill the Rest.
                if let first = model.lineup.battingOrder.first(where: { model.context.player($0)?.profile.canPlay(.p) == true }) {
                    model.assign(first, to: .field(.p), inning: 1, undoManager: undoManager)
                }
            }
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Opponent", text: $game.opponent)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.weight(.bold))
                Text(game.date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                AttendanceButton(game: game)
                ruleSetMenu
                if AIService.shared.isReady {
                    priorityMenu
                    trustMenu
                }
                ModelMenu()
            }
            VStack(alignment: .leading, spacing: 6) {
                if AIService.shared.isReady {
                    TextField("Notes", text: $game.notesForAI, axis: .vertical)
                        .help("For the AI: \"Cole pitches the 1st and 2nd,\" \"Ava's arm is sore.\"")
                }
                TextField("Scouting report on \(game.opponent.isEmpty ? "the opponent" : game.opponent)", text: $game.scoutingReport, axis: .vertical)
                    .help("What you know about this team: \"They bunt a lot,\" \"lefty-heavy lineup,\" \"fast kids at the top.\" The AI uses it when it helps; it carries over the next time you play them.")
            }
            .textFieldStyle(.plain)
            .foregroundStyle(.secondary)
            .lineLimit(1...6)
            .padding(.top, 4)
        }
    }

    private var ruleSetMenu: some View {
        Menu {
            // Selects by ID: in clean builds the compiler doesn't always see @Model's Hashable conformance here.
            Picker("Rules", selection: Binding(
                get: { game.ruleSet?.persistentModelID },
                set: { id in game.ruleSet = game.team?.ruleSets.first { $0.persistentModelID == id } }
            )) {
                Text("No Rules").tag(PersistentIdentifier?.none)
                ForEach(game.team?.sortedRuleSets ?? []) { Text($0.name).tag(Optional($0.persistentModelID)) }
            }
            .pickerStyle(.inline)
        } label: {
            Chip(game.ruleSet?.name ?? "No Rules", symbol: "list.bullet")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
    }

    private var priorityMenu: some View {
        Menu {
            Picker("Priority", selection: Binding(get: { game.priority }, set: { game.priority = $0 })) {
                ForEach(GamePriority.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Chip(game.priority == .balanced ? "Win + Develop" : game.priority.label, symbol: "trophy")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("Win ↔ Develop")
    }

    /// What the AI trusts. Without stats it can only go by ratings, so the chip says so and offers the import,
    /// with the stats choices shown but out of reach.
    private var trustMenu: some View {
        let hasStats = game.hasStats
        return Menu {
            if hasStats {
                Picker("Trust", selection: Binding(get: { game.weighting }, set: { game.weighting = $0 })) {
                    ForEach(DataWeighting.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } else {
                Button("Import GameChanger Stats…", systemImage: "chart.bar.xaxis") { importingStats = true }
                Section("With Stats") {
                    ForEach(DataWeighting.allCases.filter { $0 != .coachOnly }, id: \.self) { Button($0.label) {}.disabled(true) }
                }
            }
        } label: {
            Chip(hasStats ? game.weighting.label : DataWeighting.coachOnly.label, symbol: "chart.bar")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help(hasStats ? "What the AI trusts: GameChanger stats, your ratings, or both"
                       : "No stats yet, so the AI goes by your ratings. Import GameChanger stats to weigh them too.")
    }

    private var canUseHistory: Bool {
        (game.team?.activePlayers ?? []).contains { $0.stats != nil && $0.profile == .default }
    }

    private func runRemake() {
        guard let remake else { return }
        self.remake = nil
        if remake.step == .battingOrder {
            model.makeBattingOrder(feedback: remake.feedback, undoManager: undoManager)
        } else {
            model.setPositions(feedback: remake.feedback, undoManager: undoManager)
        }
    }

    private func useHistoryAndRetry() {
        let changed = (game.team?.activePlayers ?? []).filter { $0.applyGameChangerHistory() }.count
        model.errorMessage = nil
        if changed > 0 { model.makeBattingOrder(undoManager: undoManager) }
    }

    // MARK: Steps

    /// Batting Order › Positions — where you are, and the one next thing to do.
    /// Without AI the coach builds both steps by hand, and the AI buttons stay in view to show what it would do.
    private var stepBar: some View {
        let aiReady = AIService.shared.isReady
        return HStack(spacing: 10) {
            StepLink(title: "Batting Order", active: model.step == .battingOrder) { model.step = .battingOrder }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.quaternary)
            StepLink(title: "Positions", active: model.step == .positions) { model.preparePositions() }
                .disabled(!model.isBattingOrderComplete)
            Spacer()
            if !model.isGenerating {
                if model.step == .battingOrder {
                    if !model.hasBattingOrder && !model.hasDefense, model.lastGame != nil { copyMenu }
                    if aiReady && model.isBattingOrderComplete {
                        Button("Remake…", systemImage: "sparkles") { feedbackFor = .battingOrder }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Tell the AI what to change in the order")
                    }
                    if model.isBattingOrderComplete {
                        Button { model.preparePositions() } label: {
                            Label("Positions", systemImage: "arrow.right").padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut("g", modifiers: .command)
                    } else if aiReady && !model.hasBattingOrder {
                        Button { model.makeBattingOrder(undoManager: undoManager) } label: {
                            Label("Make Batting Order", systemImage: "sparkles").padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut("g", modifiers: .command)
                    } else if !model.hasBattingOrder {
                        AIFeatureButton(title: "Make Batting Order", feature: "Let AI Make the Batting Order",
                                        message: "AI weighs season stats, your ratings and notes, and the matchup, then explains every spot.")
                    }
                } else if !aiReady {
                    if !model.isFilled {
                        AIFeatureButton(title: "Fill Positions", feature: "Let AI Fill the Positions",
                                        message: "Set the spots you care about. AI fills the rest so every rule is met and every kid gets fair time.")
                    }
                } else {
                    if model.isFilled {
                        Button("Remake…", systemImage: "sparkles") { feedbackFor = .positions }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Tell the AI what to change. Locked spots stay.")
                    } else {
                        Button { model.setPositions(undoManager: undoManager) } label: {
                            Label(model.document.locks.isEmpty ? "Fill Positions" : "Fill the Rest", systemImage: "sparkles").padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut("g", modifiers: .command)
                    }
                }
            }
        }
    }

    /// Start from the last game's lineup (click), or pick another game (menu).
    private var copyMenu: some View {
        Menu {
            ForEach(model.copySources) { source in
                Button(Self.gameLabel(source)) { model.copyLineup(from: source, undoManager: undoManager) }
            }
        } label: {
            Label("Copy Last Game", systemImage: "doc.on.doc")
        } primaryAction: {
            if let last = model.lastGame { model.copyLineup(from: last, undoManager: undoManager) }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(model.lastGame.map { "Start from \(Self.gameLabel($0))" } ?? "")
    }

    static func gameLabel(_ game: Game) -> String {
        "\(game.opponent) · \(game.date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    @ViewBuilder
    private var stepContent: some View {
        if model.isGenerating && model.generating == .battingOrder {
            progress
        } else if model.step == .battingOrder {
            BattingOrderList(model: model)
        } else {
            if model.isGenerating {
                progress
            } else if !model.isFilled {
                Text(AIService.shared.isReady ? "Click any spot to lock it in. The AI fills the rest." : "Click a spot to pick a position.")
                    .foregroundStyle(.secondary)
                if model.hasGrid && !model.context.activeRules.isEmpty { RulesChecklist(model: model) }
            }
            LineupGridView(model: model)
            if model.isFilled { Summary(model: model).id("summary") }
        }
    }

    private var progress: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.status ?? "Thinking…").foregroundStyle(.secondary)
            Button("Cancel") { model.cancel() }.buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, model.step == .positions ? 0 : 60)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.isFilled {
                Button("Print", systemImage: "printer") { LineupCardPrinter.print(model: model) }
                    .keyboardShortcut("p", modifiers: .command)
            }
            Menu {
                let history = game.history
                Section("Versions") {
                    if history.isEmpty { Text("None yet") }
                    ForEach(history.reversed()) { version in
                        Button(version.savedAt.formatted(date: .abbreviated, time: .shortened)) {
                            model.restore(version, undoManager: undoManager)
                        }
                    }
                }
                if !model.copySources.isEmpty {
                    Menu("Copy Lineup From") {
                        ForEach(model.copySources) { source in
                            Button(Self.gameLabel(source)) { model.copyLineup(from: source, undoManager: undoManager) }
                        }
                    }
                }
                Divider()
                Button("Clear Positions") { model.clearPositions(undoManager: undoManager) }
                    .disabled(!model.hasDefense)
                Button("Clear Lineup…", role: .destructive) { confirmStartOver = true }
                    .disabled(!model.hasBattingOrder && !model.hasDefense)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// The AI that makes the lineup: the app's pinned model for the connected service (ChatGPT plan or Claude key).
/// Shown, never chosen; the menu only links to usage and Settings.
struct ModelMenu: View {
    @State private var ai = AIService.shared

    var body: some View {
        Menu {
            if ai.isReady {
                if ai.usesClaude {
                    Section("Using your Claude API key") {
                        Link("Claude Console…", destination: AnthropicClient.keysURL)
                    }
                } else {
                    Section("Using ChatGPT plan") {
                        Link("Manage Usage…", destination: ChatGPTAuth.manageUsageURL)
                    }
                }
                SettingsLink { Text("AI Settings…") }
            } else {
                SettingsLink { Text("Sign In with ChatGPT…") }
                SettingsLink { Text("Use a Claude API Key…") }
            }
        } label: {
            Chip(ai.isReady ? ai.currentModelName : "Set Up AI", symbol: "sparkles")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help(ai.isReady ? "The AI that makes this lineup · " + (ai.usesClaude ? "Using your Claude API key" : "Using ChatGPT plan") : "Let the AI make lineups")
        .task { if ai.isSignedIn && ai.chatGPTModels.isEmpty { await ai.loadModels() } }
    }
}

/// A quiet, borderless menu label: icon + value.
struct Chip: View {
    let text: String
    let symbol: String
    init(_ text: String, symbol: String) { self.text = text; self.symbol = symbol }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
    }
}

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    var prompt: String
    var onSubmit: (String) -> Void
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("What should change?", text: $feedback, prompt: Text(prompt), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remake") {
                    onSubmit(feedback)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        #if DEBUG
        .task {
            guard DebugSupport.autoRemake else { return }
            try? await Task.sleep(for: .seconds(1))
            onSubmit("Test remake")
            dismiss()
        }
        #endif
    }
}

/// One crumb in "Batting Order › Positions".
struct StepLink: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(.primary) : (isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
    }
}

/// Step 1. The order on the left; everyone here who isn't in it yet waits on the right, each chip level with an open spot.
/// Spots and chips are the same shape, so a kid drops in like a puzzle piece. Drag a kid into a spot (or double-click to
/// add them at the end), drag to reorder, drag back to take them out.
struct BattingOrderList: View {
    let model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var dragging: PlayerID?
    @State private var dropTarget: DropSpot?
    @State private var cardPlayer: PlayerID?
    @State private var editingPlayer: Player?
    @State private var importingStats = false
    /// The stat columns show team ranks, or the numbers themselves.
    @AppStorage("battingOrderShowsNumbers") private var showsNumbers = false

    private let rowHeight: CGFloat = 46
    private let chipHeight: CGFloat = 38
    private let headerHeight: CGFloat = 34
    private let statWidth: CGFloat = 46
    private let handleWidth: CGFloat = 16
    private static let metrics: [Metric] = [.avg, .obp, .slg]

    enum DropSpot: Hashable { case slot(Int), players }

    /// Team ranks on AVG, OBP and SLG, from season stats; nil when nobody here has batting stats.
    private struct Stats {
        let ranks: TeamRanks
    }

    var body: some View {
        let ctx = model.context
        let slots = model.battingSlots
        let lines = Dictionary(ctx.players.compactMap { p in p.stats?.batting.flatMap { $0.pa > 0 ? (p.id, $0) : nil } }, uniquingKeysWith: { a, _ in a })
        let stats = lines.isEmpty ? nil : model.game.team.map { Stats(ranks: $0.ranks) }
        let unplaced = sortedByAverage(model.unplacedBatters, stats)
        let ids = PromptIDs(players: ctx.players)
        let width = chipWidth(stats)

        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 0) {
                // Level with the players' header, so chips and open spots line up across.
                if stats != nil {
                    HStack(spacing: 14) {
                        Color.clear.frame(width: 26, height: 1)
                        HStack(spacing: 0) {
                            Picker("Show", selection: $showsNumbers) {
                                Text("Rank").tag(false)
                                Text("Stat").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                            .help("Team rank, or the season numbers")
                            Spacer(minLength: 0)
                            statLabels
                        }
                        .padding(.horizontal, 12)
                        .frame(width: width)
                    }
                    .frame(height: headerHeight, alignment: .top)
                } else if !unplaced.isEmpty {
                    Color.clear.frame(width: 1, height: headerHeight)
                }
                ForEach(Array(slots.enumerated()), id: \.offset) { index, id in
                    if let id, let player = ctx.player(id) {
                        batterRow(index, player, reason: model.document.battingReasons[id].map { ids.humanize($0, players: ctx.players) }, stats: stats)
                    } else {
                        openRow(index, width: width)
                    }
                }
                if !model.document.battingRationale.isEmpty && unplaced.isEmpty {
                    Text(ids.humanize(model.document.battingRationale, players: ctx.players))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                }
            }
            .frame(maxWidth: unplaced.isEmpty ? .infinity : nil, alignment: .leading)

            if !unplaced.isEmpty {
                playerTray(unplaced, stats: stats)
            }
        }
        // A drag dropped outside any target never reports back; the next plain mouse move ends it.
        .onContinuousHover { _ in
            if dragging != nil && NSEvent.pressedMouseButtons == 0 { dragging = nil; dropTarget = nil }
        }
        .gameChangerImport(team: model.game.team, isPresented: $importingStats)
        // A kid's roster page over the game; Done comes straight back to the lineup.
        .sheet(item: $editingPlayer) { player in
            PlayerEditorView(player: player, showsManagement: false)
                .frame(width: 860, height: 700)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { editingPlayer = nil } }
                }
        }
        #if DEBUG
        .task(id: slots.compactMap { $0 }.count) {
            if let name = UserDefaults.standard.string(forKey: "PMBattingCard"), slots.contains(where: { $0 != nil }) {
                try? await Task.sleep(for: .milliseconds(400))
                cardPlayer = ctx.players.first { $0.name.hasPrefix(name) }?.id
            }
        }
        #endif
    }

    /// Click a kid for their season at the plate, your evaluation, and the Scouting Report's take.
    private func card(_ player: PlayerSnapshot) -> some View {
        BattingCard(model: model, player: player, onEdit: { stored in
            cardPlayer = nil
            UserDefaults.standard.set(PlayerTab.stats.rawValue, forKey: "playerTab")
            editingPlayer = stored
        }, onImportStats: {
            cardPlayer = nil
            importingStats = true
        })
    }

    private func showsCard(_ player: PlayerSnapshot) -> Binding<Bool> {
        Binding(get: { cardPlayer == player.id }, set: { if !$0 { cardPlayer = nil } })
    }

    private func chipWidth(_ stats: Stats?) -> CGFloat {
        stats == nil ? 240 : 230 + CGFloat(Self.metrics.count) * statWidth
    }

    /// The one shape every kid takes here, in a spot or waiting. With stats, their AVG, OBP and SLG ride along.
    private func chip(_ player: PlayerSnapshot, handle: Bool, stats: Stats?) -> some View {
        HStack(spacing: 8) {
            Text(player.name).font(.title3).lineLimit(1)
            Spacer(minLength: 0)
            if let stats {
                HStack(spacing: 0) {
                    ForEach(Self.metrics, id: \.self) { metric in statCell(stats.ranks.standing(player.id, metric), metric) }
                }
            }
            Image(systemName: "line.3.horizontal").font(.callout).foregroundStyle(.tertiary)
                .frame(width: handleWidth)
                .opacity(handle ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(width: chipWidth(stats), height: chipHeight)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .opacity(dragging == player.id ? 0.35 : 1)
        .help("Click for \(InningDiamond.firstName(player))'s hitting")
    }

    /// A team rank (top three in orange) or the number itself. "–" when they haven't batted enough to rank.
    private func statCell(_ standing: Standing?, _ metric: Metric) -> some View {
        let rank = standing?.rank
        let text = showsNumbers ? standing.map { metric.format($0.value) } ?? "–" : standing?.rankText ?? "–"
        return Text(text)
            .font(.callout.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(rank.map { $0 <= 3 } == true ? AnyShapeStyle(Color.accentColor)
                             : rank == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .frame(width: statWidth, alignment: .trailing)
    }

    private var statLabels: some View {
        HStack(spacing: 0) {
            ForEach(Self.metrics, id: \.self) { metric in
                Text(metric.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .frame(width: statWidth, alignment: .trailing)
            }
            Color.clear.frame(width: handleWidth + 8, height: 1)
        }
    }

    /// Ranked batting averages first (best first), then kids too new to rank (by average), then kids without stats.
    private func sortedByAverage(_ players: [PlayerSnapshot], _ stats: Stats?) -> [PlayerSnapshot] {
        guard let stats else { return players }
        func key(_ index: Int, _ player: PlayerSnapshot) -> (Int, Double, Int) {
            guard let standing = stats.ranks.standing(player.id, .avg) else { return (2, 0, index) }
            if let rank = standing.rank { return (0, Double(rank), index) }
            return (1, -standing.value, index)
        }
        return players.enumerated().sorted { key($0.offset, $0.element) < key($1.offset, $1.element) }.map(\.element)
    }

    private func number(_ n: Int, open: Bool) -> some View {
        Text("\(n)")
            .font(.title3.monospacedDigit())
            .foregroundStyle(open ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tertiary))
            .frame(width: 26, alignment: .trailing)
    }

    /// A filled spot. Dropping a kid here puts them in this spot; the others shift toward the nearest gap.
    private func batterRow(_ index: Int, _ player: PlayerSnapshot, reason: String?, stats: Stats?) -> some View {
        let lit = dropTarget == .slot(index) && dragging != nil && dragging != player.id
        return HStack(spacing: 14) {
            number(index + 1, open: false)
            chip(player, handle: true, stats: stats)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(lit ? Color.accentColor : Color.clear, lineWidth: 2))
                .contentShape(Rectangle())
                .onTapGesture { cardPlayer = player.id }
                .onDrag { drag(player) } preview: { preview(player) }
                .popover(isPresented: showsCard(player), arrowEdge: .trailing) { card(player) }
                .contextMenu {
                    Button("Remove from Batting Order") { withAnimation(.snappy) { model.removeBatter(player.id, undoManager: undoManager) } }
                }
            if let reason, !reason.isEmpty {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(reason)
            }
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], isTargeted: targeted(.slot(index))) { _ in drop(on: .slot(index)) }
    }

    /// An empty spot, the exact shape of a chip. A kid dropped here takes this spot.
    private func openRow(_ index: Int, width: CGFloat) -> some View {
        let lit = dropTarget == .slot(index) && dragging != nil
        return HStack(spacing: 14) {
            number(index + 1, open: true)
            RoundedRectangle(cornerRadius: 8)
                .fill(lit ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
                .strokeBorder(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: width, height: chipHeight)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], isTargeted: targeted(.slot(index))) { _ in drop(on: .slot(index)) }
    }

    /// Waiting kids, best batting average first when there are stats. With stats the header carries the
    /// column labels, so Add All moves below the list.
    private func playerTray(_ unplaced: [PlayerSnapshot], stats: Stats?) -> some View {
        let addAll = Button("Add All") {
            withAnimation(.snappy) { for player in unplaced { model.placeBatter(player.id, inSlot: nil, undoManager: undoManager) } }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Add everyone in this order, then drag to reorder")

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Players").font(.headline)
                Spacer()
                if stats != nil { statLabels } else { addAll }
            }
            .padding(.trailing, stats == nil ? 0 : 12)
            .frame(width: chipWidth(stats), height: headerHeight, alignment: .top)
            ForEach(unplaced) { player in
                chip(player, handle: false, stats: stats)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { withAnimation(.snappy) { model.placeBatter(player.id, inSlot: nil, undoManager: undoManager) } }
                    .onTapGesture { cardPlayer = player.id }
                    .onDrag { drag(player) } preview: { preview(player) }
                    .popover(isPresented: showsCard(player), arrowEdge: .leading) { card(player) }
                    .contextMenu {
                        Button("Add to Batting Order") { withAnimation(.snappy) { model.placeBatter(player.id, inSlot: nil, undoManager: undoManager) } }
                    }
                    .frame(height: rowHeight)
            }
            if stats != nil {
                addAll.padding(.top, 6)
            } else {
                Unlock(kind: .stats, title: "Team Ranks", message: "See where each kid ranks in AVG, OBP and SLG as you set the order.",
                       team: model.game.team, compact: true)
                    .frame(width: chipWidth(stats), alignment: .leading)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 8)
        .background(dropTarget == .players ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.plainText], isTargeted: targeted(.players)) { _ in drop(on: .players) }
    }

    // MARK: Drag and drop

    private func drag(_ player: PlayerSnapshot) -> NSItemProvider {
        dragging = player.id
        return NSItemProvider(object: player.id.uuidString as NSString)
    }

    private func preview(_ player: PlayerSnapshot) -> some View {
        Text(player.name).font(.title3).lineLimit(1).padding(.horizontal, 12)
            .frame(width: 240, height: chipHeight, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func targeted(_ spot: DropSpot) -> Binding<Bool> {
        Binding(get: { dropTarget == spot }, set: { dropTarget = $0 ? spot : (dropTarget == spot ? nil : dropTarget) })
    }

    private func drop(on spot: DropSpot) -> Bool {
        defer { dragging = nil; dropTarget = nil }
        guard let dragging else { return false }
        withAnimation(.snappy) {
            switch spot {
            case .slot(let index): model.placeBatter(dragging, inSlot: index, undoManager: undoManager)
            case .players: model.removeBatter(dragging, undoManager: undoManager)
            }
        }
        return true
    }
}

// MARK: - Attendance

/// "12 Players" chip; click to check off who's coming.
struct AttendanceButton: View {
    @Bindable var game: Game
    @State private var showing = false

    var body: some View {
        let players = game.team?.activePlayers ?? []
        let coming = players.filter { (game.availability[$0.uid] ?? .present).present }.count
        Button { showing.toggle() } label: {
            Chip(coming == players.count ? "\(coming) Players" : "\(coming) of \(players.count) Players", symbol: "person.2")
                .foregroundStyle(coming < 9 ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .help(coming < 9 ? "Only \(coming) coming. You need 9 to field a team." : "Who's coming to this game")
        .popover(isPresented: $showing, arrowEdge: .bottom) { AttendanceList(game: game) }
        #if DEBUG
        .task { if DebugSupport.showAttendance { try? await Task.sleep(for: .seconds(2)); showing = true } }
        #endif
    }
}

/// Who's coming: one check per kid. Kids who aren't coming say Out.
struct AttendanceList: View {
    @Bindable var game: Game

    var body: some View {
        let players = game.team?.activePlayers ?? []
        let coming = players.filter { isComing($0) }.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Who's Coming").font(.headline)
                Spacer()
                Text("\(coming) of \(players.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ForEach(players) { player in
                let on = isComing(player)
                Toggle(isOn: Binding(get: { on }, set: { set(player, coming: $0) })) {
                    HStack {
                        Text(player.name).foregroundStyle(on ? .primary : .secondary)
                        Spacer()
                        if !on { Text("Out").foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            HStack(spacing: 10) {
                if coming < 9 {
                    Label("Only \(coming) coming. You need 9 to field a team.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                if coming < players.count {
                    Button("Everyone's Coming") { game.availability = [:] }.buttonStyle(.link)
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .frame(width: 340)
    }

    private func isComing(_ player: Player) -> Bool { (game.availability[player.uid] ?? .present).present }

    private func set(_ player: Player, coming: Bool) {
        var all = game.availability
        all[player.uid] = coming ? nil : .absent
        game.availability = all
    }
}

// MARK: - Summary under the grid

/// One line when all is well; details only when asked for or when something's wrong.
struct Summary: View {
    let model: GameModel
    @State private var expanded = false

    var body: some View {
        let violations = model.findings.violations
        let rules = model.context.activeRules
        let checked = rules.filter { $0.check != nil }
        let judged = rules.filter { $0.check == nil }
        // Live, so a spot the coach has since changed no longer counts.
        let adjusted = model.document.provenance.values.filter { $0 == .appAdjusted }.count

        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    if violations.isEmpty {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Follows your rules")
                        if !model.document.warnings.isEmpty {
                            Text("· \(model.document.warnings.count) note\(model.document.warnings.count == 1 ? "" : "s")").foregroundStyle(.orange)
                        }
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(violations.count == 1 ? "1 problem" : "\(violations.count) problems")
                    }
                    if adjusted > 0 {
                        Text("· \(adjusted) spot\(adjusted == 1 ? "" : "s") changed by the app").foregroundStyle(.orange)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .disabled(!model.hasDefense && violations.isEmpty)
            .help(adjusted > 0 ? "The AI couldn't fix a rule problem, so the app made the smallest change that does. Those spots are outlined in orange." : "")

            if !violations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(violations) { Text($0.message).foregroundStyle(.secondary) }
                }
                .font(.callout)
            }

            if expanded && model.hasDefense {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checked) { rule in
                        let failed = violations.contains { $0.ruleID == rule.id }
                        RuleLine(text: rule.text, symbol: failed ? "xmark" : "checkmark", tint: failed ? .red : .green)
                    }
                    ForEach(judged) { rule in
                        RuleLine(text: rule.text, symbol: "sparkles", tint: .secondary)
                            .help("Judged by the AI, not checked by the app")
                    }
                    ForEach(model.document.warnings, id: \.self) { warning in
                        RuleLine(text: warning, symbol: "exclamationmark.triangle", tint: .orange)
                    }
                    if adjusted > 0 {
                        RuleLine(text: "Outlined spots were changed by the app, because the AI couldn't fix a rule", symbol: "wrench.adjustable", tint: .orange)
                    }
                }
                .font(.callout)
                .padding(.leading, 2)
            }

            let plan = [model.document.battingRationale, model.document.defenseRationale].filter { !$0.isEmpty }
            if !plan.isEmpty {
                Text(PromptIDs(players: model.context.players).humanize(plan.joined(separator: " "), players: model.context.players))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The game's rules beside the work while the coach builds by hand. Checked rules show ✓, or ✗ with who breaks
/// them, as spots are placed; rules the app can't check are reminders (the AI weighs them when it's set up).
struct RulesChecklist: View {
    let model: GameModel

    var body: some View {
        let violations = model.findings.violations
        let ctx = model.context
        VStack(alignment: .leading, spacing: 8) {
            Caption(model.game.ruleSet.map { "\($0.name) Rules" } ?? "Rules")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 24, alignment: .topLeading)], alignment: .leading, spacing: 6) {
                ForEach(ctx.activeRules) { rule in
                    let broken = violations.filter { $0.ruleID == rule.id }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: rule.check == nil ? "circle" : broken.isEmpty ? "checkmark" : "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(rule.check == nil ? AnyShapeStyle(.tertiary) : broken.isEmpty ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.red))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.text).foregroundStyle(rule.check == nil ? .secondary : .primary)
                            if !broken.isEmpty {
                                Text(Self.names(broken, ctx)).foregroundStyle(.red)
                            }
                        }
                        .lineLimit(2)
                    }
                    .font(.callout)
                    .help(rule.check == nil
                          ? (AIService.shared.isReady ? "The AI weighs this one; the app can't check it" : "A reminder: the app can't check this one")
                          : broken.map(\.message).joined(separator: "\n"))
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func names(_ findings: [Finding], _ ctx: GameContext) -> String {
        var seen = Set<PlayerID>()
        return findings.compactMap(\.player).filter { seen.insert($0).inserted }
            .map { ctx.name($0).components(separatedBy: " ").first ?? "" }.joined(separator: ", ")
    }
}

struct RuleLine: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

extension GameModel.Step: Identifiable {
    var id: Self { self }
}
