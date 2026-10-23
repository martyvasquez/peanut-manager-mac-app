import SwiftUI
import SwiftData
import LineupKit
import LineupAI

struct GamesListView: View {
    @Environment(\.modelContext) private var context
    let team: Team
    @Binding var selection: Game?
    @State private var showingNewGame = false

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
            if games.isEmpty {
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
        }
        .sheet(isPresented: $showingNewGame) {
            NewGameSheet(team: team) { selection = $0 }
        }
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
    @State private var confirmStartOver = false

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
        .sheet(item: $feedbackFor) { step in
            FeedbackSheet(prompt: step == .battingOrder ? "Bat Mia leadoff" : "Move Jake to the outfield") { feedback in
                if step == .battingOrder {
                    model.makeBattingOrder(feedback: feedback, undoManager: undoManager)
                } else {
                    model.setPositions(feedback: feedback, undoManager: undoManager)
                }
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
            if DebugSupport.copyLastGame && !model.hasBattingOrder, let last = model.lastGame { model.copyLineup(from: last, undoManager: undoManager) }
            if DebugSupport.autoGenerate && !model.hasBattingOrder { model.makeBattingOrder(undoManager: undoManager) }
            if DebugSupport.autoPositions && model.hasBattingOrder && !model.isFilled { model.setPositions(undoManager: undoManager) }
            #endif
        }
        #if DEBUG
        .onChange(of: model.hasBattingOrder) {
            if DebugSupport.autoPositions && model.hasBattingOrder && !model.isFilled { model.setPositions(undoManager: undoManager) }
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

    private var trustMenu: some View {
        Menu {
            Picker("Trust", selection: Binding(get: { game.weighting }, set: { game.weighting = $0 })) {
                ForEach(DataWeighting.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Chip(game.weighting.label, symbol: "chart.bar")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("What the AI trusts: GameChanger stats, your ratings, or both")
    }

    private var canUseHistory: Bool {
        (game.team?.activePlayers ?? []).contains { $0.stats != nil && $0.profile == .default }
    }

    private func useHistoryAndRetry() {
        let changed = (game.team?.activePlayers ?? []).filter { $0.applyGameChangerHistory() }.count
        model.errorMessage = nil
        if changed > 0 { model.makeBattingOrder(undoManager: undoManager) }
    }

    // MARK: Steps

    /// Batting Order › Positions — where you are, and the one next thing to do.
    /// Without AI the coach builds both steps by hand; with it, the AI can do either.
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
                    }
                } else if aiReady {
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

/// Which model makes the lineup: ChatGPT (the coach's plan) or Claude (the coach's API key).
struct ModelMenu: View {
    @State private var ai = AIService.shared

    var body: some View {
        Menu {
            if ai.isReady {
                // Picking the default model follows the default (Settings can pin it).
                let selection = Binding(get: { ai.modelID }, set: { ai.chosenModelID = $0 == ai.defaultModelID ? nil : $0 })
                if ai.isSignedIn {
                    Picker("ChatGPT", selection: selection) {
                        if ai.chatGPTModels.isEmpty && !ai.usesClaude { Text(ai.currentModelName).tag(ai.modelID) }
                        ForEach(ai.chatGPTModels) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                }
                if ai.hasClaudeKey {
                    Picker("Claude", selection: selection) {
                        ForEach(AnthropicClient.models) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                }
                Divider()
                if ai.usesClaude {
                    Section("Using your Claude API key") {
                        Link("Claude Console…", destination: AnthropicClient.keysURL)
                    }
                } else {
                    Section("Using ChatGPT plan") {
                        Link("Manage Usage…", destination: ChatGPTAuth.manageUsageURL)
                    }
                }
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

/// Step 1: the batting order as a list. Drag to reorder; each player's reason sits beside them.
/// Step 1. The order on the left; everyone here who isn't in it yet waits on the right.
/// Drag a player into a spot (or double-click to add them at the end), drag to reorder, drag back to take them out.
struct BattingOrderList: View {
    let model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var dragging: PlayerID?
    @State private var dropTarget: DropSpot?

    private let rowHeight: CGFloat = 52

    enum DropSpot: Hashable { case batter(PlayerID), end, players }

    var body: some View {
        let ctx = model.context
        let placed = model.placedBatters.compactMap { ctx.player($0) }
        let unplaced = model.unplacedBatters
        let ids = PromptIDs(players: ctx.players)

        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    ForEach(Array(placed.enumerated()), id: \.element.id) { index, player in
                        batterRow(index + 1, player, reason: model.document.battingReasons[player.id].map { ids.humanize($0, players: ctx.players) }, placed: placed)
                    }
                    ForEach(0..<unplaced.count, id: \.self) { offset in
                        openRow(placed.count + offset + 1, first: offset == 0)
                    }
                }
                if !model.document.battingRationale.isEmpty && unplaced.isEmpty {
                    Text(ids.humanize(model.document.battingRationale, players: ctx.players))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Narrow while players wait, so a drag from the tray is short.
            .frame(maxWidth: unplaced.isEmpty ? .infinity : 520, alignment: .leading)

            if !unplaced.isEmpty {
                playerTray(unplaced, placed: placed)
                    .frame(width: 220)
            }
        }
    }

    private func batterRow(_ number: Int, _ player: PlayerSnapshot, reason: String?, placed: [PlayerSnapshot]) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .trailing)
            Text(player.name).font(.title3)
            if let reason, !reason.isEmpty {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(reason)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").foregroundStyle(.quaternary)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5) }
        .overlay(alignment: lineEdge(for: player.id, placed: placed)) {
            if dropTarget == .batter(player.id) && dragging != player.id {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: lineEdge(for: player.id, placed: placed) == .top ? -1.5 : 1.5)
            }
        }
        .opacity(dragging == player.id ? 0.4 : 1)
        .onDrag { drag(player) } preview: { preview(player) }
        .onDrop(of: [.plainText], isTargeted: targeted(.batter(player.id))) { _ in drop(on: .batter(player.id), placed: placed) }
        .contextMenu {
            Button("Remove from Batting Order") { withAnimation(.snappy) { model.removeBatter(player.id, undoManager: undoManager) } }
        }
    }

    /// An empty spot. Dropping on any of them adds the player at the end of the order.
    private func openRow(_ number: Int, first: Bool) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.quaternary)
                .frame(width: 26, alignment: .trailing)
            RoundedRectangle(cornerRadius: 8)
                .fill(first && dropTarget == .end ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(height: 36)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], isTargeted: targeted(.end)) { _ in drop(on: .end, placed: []) }
    }

    private func playerTray(_ unplaced: [PlayerSnapshot], placed: [PlayerSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Players").font(.headline)
                Spacer()
                Button("Add All") {
                    withAnimation(.snappy) { for player in unplaced { model.placeBatter(player.id, at: nil, undoManager: undoManager) } }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Add everyone in roster order, then drag to reorder")
            }
            .padding(.bottom, 4)
            ForEach(unplaced) { player in
                Text(player.name)
                    .font(.title3)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .opacity(dragging == player.id ? 0.4 : 1)
                    .onTapGesture(count: 2) { withAnimation(.snappy) { model.placeBatter(player.id, at: nil, undoManager: undoManager) } }
                    .onDrag { drag(player) } preview: { preview(player) }
                    .contextMenu {
                        Button("Add to Batting Order") { withAnimation(.snappy) { model.placeBatter(player.id, at: nil, undoManager: undoManager) } }
                    }
                    .help("Drag into the batting order, or double-click to add")
            }
        }
        .padding(10)
        .background(dropTarget == .players ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.plainText], isTargeted: targeted(.players)) { _ in drop(on: .players, placed: placed) }
    }

    // MARK: Drag and drop

    private func drag(_ player: PlayerSnapshot) -> NSItemProvider {
        dragging = player.id
        return NSItemProvider(object: player.id.uuidString as NSString)
    }

    private func preview(_ player: PlayerSnapshot) -> some View {
        Text(player.name).font(.title3).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    private func targeted(_ spot: DropSpot) -> Binding<Bool> {
        Binding(get: { dropTarget == spot }, set: { dropTarget = $0 ? spot : (dropTarget == spot ? nil : dropTarget) })
    }

    private func drop(on spot: DropSpot, placed: [PlayerSnapshot]) -> Bool {
        defer { dragging = nil; dropTarget = nil }
        guard let dragging else { return false }
        withAnimation(.snappy) {
            switch spot {
            case .batter(let target): model.placeBatter(dragging, at: target, undoManager: undoManager)
            case .end: model.placeBatter(dragging, at: nil, undoManager: undoManager)
            case .players: model.removeBatter(dragging, undoManager: undoManager)
            }
        }
        return true
    }

    /// Moving down drops below the target row; moving up, or in from the players, drops above it.
    private func lineEdge(for target: PlayerID, placed: [PlayerSnapshot]) -> Alignment {
        guard let dragging,
              let from = placed.firstIndex(where: { $0.id == dragging }),
              let to = placed.firstIndex(where: { $0.id == target }) else { return .top }
        return from < to ? .bottom : .top
    }
}

// MARK: - Attendance

/// "12 Players" chip; click to check off who's coming.
struct AttendanceButton: View {
    @Bindable var game: Game
    @State private var showing = false

    var body: some View {
        let players = game.team?.activePlayers ?? []
        let availability = game.availability
        let present = players.filter { (availability[$0.uid] ?? .present).present }.count
        Button { showing.toggle() } label: {
            Chip(present == players.count ? "\(present) Players" : "\(present) of \(players.count) Players", symbol: "person.2")
                .foregroundStyle(present < 9 ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(players) { AttendanceRow(game: game, player: $0) }
            }
            .padding(.vertical, 8)
            .frame(width: 340)
        }
    }
}

struct AttendanceRow: View {
    @Bindable var game: Game
    let player: Player
    @State private var hovering = false

    private var availability: Availability { game.availability[player.uid] ?? .present }

    private func update(_ change: (inout Availability) -> Void) {
        var all = game.availability
        var a = all[player.uid] ?? .present
        change(&a)
        all[player.uid] = a
        game.availability = all
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { availability.present }, set: { value in update { $0.present = value } })) {
                Text(player.name).foregroundStyle(availability.present ? .primary : .secondary)
            }
            .toggleStyle(.checkbox)
            Spacer()
            if availability.present {
                Menu {
                    Picker("Arrives", selection: Binding(get: { availability.arrivesInning ?? 1 }, set: { value in update { $0.arrivesInning = value == 1 ? nil : value } })) {
                        Text("On Time").tag(1)
                        ForEach(2...max(game.innings, 2), id: \.self) { Text("Inning \($0)").tag($0) }
                    }
                    Picker("Leaves", selection: Binding(get: { availability.leavesAfterInning ?? game.innings }, set: { value in update { $0.leavesAfterInning = value >= game.innings ? nil : value } })) {
                        Text("Stays").tag(game.innings)
                        ForEach(1..<max(game.innings, 2), id: \.self) { Text("After \($0)").tag($0) }
                    }
                } label: {
                    Text(timing).font(.caption).foregroundStyle(availability.isPartial ? .orange : .secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .opacity(availability.isPartial || hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
    }

    private var timing: String {
        switch (availability.arrivesInning, availability.leavesAfterInning) {
        case (nil, nil): "All game"
        case (let a?, nil): "From \(a)"
        case (nil, let l?): "Through \(l)"
        case (let a?, let l?): "\(a)–\(l)"
        }
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
