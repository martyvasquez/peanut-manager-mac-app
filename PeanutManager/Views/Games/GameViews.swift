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
            if game.document?.lineup.hasDefense == true {
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
    @State private var showingFeedback = false
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
                    if model.hasBattingOrder || model.hasDefense {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LineupGridView(model: model)
                        }
                        Summary(model: model).id("summary")
                    } else if !model.isGenerating {
                        generateButton
                    }
                    if model.isGenerating { progress }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if DEBUG
            .onChange(of: model.hasDefense) {
                if DebugSupport.scrollToChecks {
                    Task { try? await Task.sleep(for: .milliseconds(300)); withAnimation { proxy.scrollTo("summary", anchor: .bottom) } }
                }
            }
            #endif
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheet { feedback, battingToo in
                model.generate(battingToo: battingToo, feedback: feedback, undoManager: undoManager)
            }
        }
        .alert("Couldn't Make a Lineup", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.errorMessage?.contains("Settings") == true {
                SettingsLink { Text("Open Settings") }
            }
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Clear this lineup?", isPresented: $confirmStartOver) {
            Button("Clear Lineup", role: .destructive) { model.startOver(undoManager: undoManager) }
        } message: {
            Text("You can undo, or restore it from Versions.")
        }
        .task {
            #if DEBUG
            if DebugSupport.autoGenerate && !model.hasDefense { model.generate(undoManager: undoManager) }
            #endif
        }
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

    // MARK: States

    private var generateButton: some View {
        Button {
            model.generate(battingToo: !model.hasBattingOrder, undoManager: undoManager)
        } label: {
            Label("Make Lineup", systemImage: "sparkles")
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

    private var progress: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.status ?? "Thinking…").foregroundStyle(.secondary)
            Button("Cancel") { model.cancel() }.buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, model.hasDefense ? 0 : 40)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.hasDefense {
                Button("Remake", systemImage: "sparkles") { showingFeedback = true }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(model.isGenerating)
                    .help("Remake the lineup (⌘G). Locked spots stay.")
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
                Button("Clear Lineup…", role: .destructive) { confirmStartOver = true }
                    .disabled(!model.hasBattingOrder && !model.hasDefense)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
    }
}

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSubmit: (String, Bool) -> Void
    @State private var feedback = ""
    @State private var battingToo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("What should change?", text: $feedback, prompt: Text("Move Jake to the outfield"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(3...8)
            Toggle("Batting order too", isOn: $battingToo)
                .toggleStyle(.checkbox)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remake") {
                    onSubmit(feedback, battingToo)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
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
