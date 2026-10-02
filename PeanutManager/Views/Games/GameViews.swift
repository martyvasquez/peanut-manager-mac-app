import SwiftUI
import SwiftData
import LineupKit

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
            if game.document?.generatedAt != nil && game.document?.lineup.hasDefense == true {
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
                    if model.hasBattingOrder || model.isGenerating {
                        VStack(alignment: .leading, spacing: 18) {
                            stepBar
                            stepContent
                        }
                    } else {
                        startButton
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
                if model.errorMessage?.contains("Settings") == true {
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
        .confirmationDialog("Clear this lineup?", isPresented: $confirmStartOver) {
            Button("Clear Lineup", role: .destructive) { model.startOver(undoManager: undoManager) }
        } message: {
            Text("You can undo, or restore it from Versions.")
        }
        .task {
            #if DEBUG
            if DebugSupport.autoGenerate && !model.hasBattingOrder { model.makeBattingOrder(undoManager: undoManager) }
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
                inningsMenu
                priorityMenu
                trustMenu
                ModelMenu()
            }
            TextField("Notes", text: $game.notesForAI, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1...6)
                .padding(.top, 4)
                .help("Anything the AI should know: \"Cole pitches the 1st and 2nd,\" \"their lineup is lefty-heavy.\"")
        }
    }

    private var ruleSetMenu: some View {
        Menu {
            Picker("Rules", selection: $game.ruleSet) {
                Text("No Rules").tag(RuleSet?.none)
                ForEach(game.team?.sortedRuleSets ?? []) { Text($0.name).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            Chip(game.ruleSet?.name ?? "No Rules", symbol: "list.bullet")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
    }

    private var inningsMenu: some View {
        Menu {
            Picker("Innings", selection: Binding(get: { game.innings }, set: { model.setInnings($0, undoManager: undoManager) })) {
                ForEach([3, 4, 5, 6, 7, 9], id: \.self) { Text("\($0) Innings").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Chip("\(game.innings) Innings", symbol: "number")
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

    private var startButton: some View {
        Button {
            model.makeBattingOrder(undoManager: undoManager)
        } label: {
            Label("Make Batting Order", systemImage: "sparkles")
                .font(.title3.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .keyboardShortcut("g", modifiers: .command)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// Batting Order › Positions — where you are, and the one next thing to do.
    private var stepBar: some View {
        HStack(spacing: 10) {
            StepLink(title: "Batting Order", active: model.step == .battingOrder) { model.step = .battingOrder }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.quaternary)
            StepLink(title: "Positions", active: model.step == .positions) { model.preparePositions() }
                .disabled(!model.hasBattingOrder)
            Spacer()
            if !model.isGenerating {
                if model.step == .battingOrder || model.isFilled {
                    Button("Remake…", systemImage: "sparkles") { feedbackFor = model.step }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(model.step == .battingOrder ? "Tell the AI what to change in the order" : "Tell the AI what to change. Locked spots stay.")
                }
                if model.step == .battingOrder {
                    Button { model.preparePositions() } label: {
                        Label("Positions", systemImage: "arrow.right").padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .keyboardShortcut("g", modifiers: .command)
                } else if !model.isFilled {
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
                Text("Click any spot to lock it in. The AI fills the rest.")
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

/// Which AI makes the lineup. Lists the models pinned in Settings → Models.
struct ModelMenu: View {
    @State private var library = ModelLibrary.shared

    var body: some View {
        Menu {
            Picker("Model", selection: $library.selectedID) {
                ForEach(library.models) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            Divider()
            SettingsLink { Text("More Models…") }
        } label: {
            Chip(library.selected.name, symbol: "sparkles")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("The AI that makes this lineup")
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
struct BattingOrderList: View {
    let model: GameModel
    @Environment(\.undoManager) private var undoManager

    private let rowHeight: CGFloat = 52

    var body: some View {
        let ctx = model.context
        let order = model.rows.filter { ctx.availability(of: $0.id).present }
        let ids = PromptIDs(players: ctx.players)

        VStack(alignment: .leading, spacing: 16) {
            List {
                ForEach(Array(order.enumerated()), id: \.element.id) { index, player in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .trailing)
                        Text(player.name).font(.title3)
                        if let reason = model.document.battingReasons[player.id], !reason.isEmpty {
                            Text(ids.humanize(reason, players: ctx.players))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(reason)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "line.3.horizontal").foregroundStyle(.quaternary)
                    }
                    .frame(height: rowHeight)
                    .listRowSeparator(.visible)
                }
                .onMove { source, destination in
                    withAnimation(.snappy) { model.moveBatters(fromOffsets: source, toOffset: destination, undoManager: undoManager) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(order.count) * (rowHeight + 1) + 8)

            if !model.document.battingRationale.isEmpty {
                Text(ids.humanize(model.document.battingRationale, players: ctx.players))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .disabled(!model.hasDefense && violations.isEmpty)

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
                    if model.document.appAdjustedCount > 0 {
                        RuleLine(text: "\(model.document.appAdjustedCount) spots adjusted by the app (outlined)", symbol: "wrench.adjustable", tint: .orange)
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
