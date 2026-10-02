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
        let past = games.filter(\.isPast).reversed()

        List(selection: $selection) {
            if !upcoming.isEmpty {
                Section("Upcoming") { ForEach(upcoming) { GameRow(game: $0).tag($0) } }
            }
            if !past.isEmpty {
                Section("Past") { ForEach(Array(past)) { GameRow(game: $0).tag($0) } }
            }
        }
        .navigationTitle("Games")
        .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        .overlay {
            if games.isEmpty {
                ContentUnavailableView {
                    Label("No Games", systemImage: "calendar")
                } actions: {
                    Button("Add Game") { showingNewGame = true }
                }
            }
        }
        .toolbar {
            Button("Add Game", systemImage: "plus") { showingNewGame = true }
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
        VStack(alignment: .leading, spacing: 2) {
            Text("vs \(game.opponent)")
            HStack(spacing: 6) {
                Text(game.date.formatted(date: .abbreviated, time: .omitted))
                if game.document?.lineup.hasDefense == true {
                    Label("Lineup ready", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
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
    @State private var innings = 6
    @State private var ruleSet: RuleSet?

    var body: some View {
        Form {
            TextField("Opponent", text: $opponent)
            DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
            Picker("Innings", selection: $innings) { ForEach([3, 4, 5, 6, 7, 9], id: \.self) { Text("\($0)").tag($0) } }
            Picker("Rules", selection: $ruleSet) {
                Text("None").tag(RuleSet?.none)
                ForEach(team.sortedRuleSets) { Text($0.name).tag(Optional($0)) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .navigationTitle("New Game")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let game = Game(opponent: opponent.trimmingCharacters(in: .whitespaces), date: date, innings: innings)
                    context.insert(game)
                    game.team = team
                    game.ruleSet = ruleSet
                    // Carry over the last game's settings so the night-before path is one click.
                    if let last = team.games.filter({ $0 !== game }).max(by: { $0.date < $1.date }) {
                        game.priority = last.priority
                        game.weighting = last.weighting
                        if ruleSet == nil { game.ruleSet = last.ruleSet }
                    }
                    onCreate(game)
                    dismiss()
                }
                .disabled(opponent.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            innings = team.defaultInnings
            ruleSet = team.sortedRuleSets.first
        }
    }
}

// MARK: - Game detail

struct GameDetailView: View {
    @Bindable var game: Game
    @State private var model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var showingFeedback = false
    @State private var showingDetails = false
    @State private var confirmStartOver = false

    init(game: Game) {
        self.game = game
        _model = State(initialValue: GameModel(game: game))
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                setup
                AttendanceSection(game: game)
                actionBar
                if model.hasBattingOrder || model.hasDefense {
                    ScrollView(.horizontal) {
                        LineupGridView(model: model)
                            .padding(10)
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    gridLegend
                    HStack(alignment: .top, spacing: 16) {
                        GamePlanView(model: model).frame(maxWidth: .infinity, alignment: .topLeading)
                        ChecksView(model: model).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .id("checks")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if DEBUG
        .onChange(of: model.hasDefense) {
            if DebugSupport.scrollToChecks { Task { try? await Task.sleep(for: .milliseconds(300)); withAnimation { proxy.scrollTo("checks", anchor: .bottom) } } }
        }
        #endif
        }
        .navigationTitle("vs \(game.opponent)")
        .navigationSubtitle(game.date.formatted(date: .complete, time: .shortened))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    let history = game.history
                    if history.isEmpty { Text("No earlier versions") }
                    ForEach(history.reversed()) { version in
                        Button("\(version.label) — \(version.savedAt.formatted(date: .omitted, time: .shortened))") {
                            model.restore(version, undoManager: undoManager)
                        }
                    }
                } label: {
                    Label("Versions", systemImage: "clock.arrow.circlepath")
                }
                .help("Earlier versions of this lineup")
                Button("Print Lineup Card", systemImage: "printer") { LineupCardPrinter.print(model: model) }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!model.hasDefense)
            }
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheet { feedback, battingToo in
                model.generate(battingToo: battingToo, feedback: feedback, undoManager: undoManager)
            }
        }
        .alert("Couldn't Generate the Lineup", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
            if model.errorMessage?.contains("Settings") == true {
                SettingsLink { Text("Open Settings") }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            #if DEBUG
            if DebugSupport.autoGenerate && !model.hasDefense { model.generate(undoManager: undoManager) }
            #endif
        }
        .confirmationDialog("Start over?", isPresented: $confirmStartOver) {
            Button("Start Over", role: .destructive) { model.startOver(undoManager: undoManager) }
        } message: {
            Text("This clears the batting order, defense and locks. The current lineup is saved under Versions, and you can undo.")
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Picker("Rules", selection: $game.ruleSet) {
                    Text("None").tag(RuleSet?.none)
                    ForEach(game.team?.sortedRuleSets ?? []) { Text($0.name).tag(Optional($0)) }
                }
                .fixedSize()
                Picker("Innings", selection: Binding(get: { game.innings }, set: { model.setInnings($0, undoManager: undoManager) })) {
                    ForEach([3, 4, 5, 6, 7, 9], id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                Picker("Trust", selection: Binding(get: { game.weighting }, set: { game.weighting = $0 })) {
                    ForEach(DataWeighting.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help("How much the AI trusts GameChanger stats vs. your ratings")
            }
            HStack(spacing: 10) {
                Text("Win").font(.caption).foregroundStyle(.secondary)
                Picker("Priority", selection: Binding(get: { game.priority }, set: { game.priority = $0 })) {
                    ForEach(GamePriority.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 440)
                Text("Develop").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Scouting & notes for the AI", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Scouting report", text: $game.scoutingReport, prompt: Text("e.g. They bunt a lot; lefty-heavy lineup"), axis: .vertical)
                    TextField("Notes for AI", text: $game.notesForAI, prompt: Text("e.g. Cole should pitch the 1st and 2nd"), axis: .vertical)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if model.isGenerating {
                ProgressView().controlSize(.small)
                Text(model.status ?? "Working…").foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
            } else if model.hasDefense {
                Button("Regenerate…", systemImage: "sparkles") { showingFeedback = true }
                    .keyboardShortcut("g", modifiers: .command)
                    .help("Tell the AI what to change. Locked cells stay put.")
                Button("Start Over", role: .destructive) { confirmStartOver = true }
                Spacer()
                if let cost = model.document.cost, cost > 0 {
                    Text("AI cost so far: \(cost, format: .currency(code: "USD").precision(.fractionLength(2...3)))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                Button {
                    model.generate(battingToo: !model.hasBattingOrder, undoManager: undoManager)
                } label: {
                    Label(model.hasBattingOrder ? "Fill the Defense" : "Generate Lineup", systemImage: "sparkles")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("g", modifiers: .command)
                Text("Batting order and defense for every inning, checked against your rules.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var gridLegend: some View {
        HStack(spacing: 14) {
            Text("Double-click a cell, or select it and type 1–9 (scorebook) · 0 to sit · Space to lock · ⌥↑↓ to move a batter")
            Spacer()
            Label("Locked", systemImage: "lock.fill")
            Label("Adjusted by app", systemImage: "square").foregroundStyle(.orange)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSubmit: (String, Bool) -> Void
    @State private var feedback = ""
    @State private var battingToo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should change?").font(.headline)
            TextEditor(text: $feedback)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text("e.g. \"Move Jake to the outfield,\" \"Ava should catch the first three.\" Leave blank for a fresh take. Locked cells stay put.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Also redo the batting order", isOn: $battingToo)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Regenerate") {
                    onSubmit(feedback, battingToo)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

// MARK: - Attendance

struct AttendanceSection: View {
    @Bindable var game: Game
    @State private var expanded = false

    var body: some View {
        let players = game.team?.activePlayers ?? []
        let availability = game.availability
        let present = players.filter { (availability[$0.uid] ?? .present).present }.count

        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(players) { player in
                    AttendanceRow(game: game, player: player)
                    Divider()
                }
                HStack {
                    Button("Everyone's Here") { game.availability = [:] }
                    Spacer()
                }
                .buttonStyle(.link)
                .padding(.top, 6)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Who's Coming").font(.headline)
                Text("\(present) of \(players.count)").foregroundStyle(present < 9 ? .red : .secondary)
            }
        }
    }
}

struct AttendanceRow: View {
    @Bindable var game: Game
    let player: Player

    private var availability: Availability { game.availability[player.uid] ?? .present }

    private func update(_ change: (inout Availability) -> Void) {
        var all = game.availability
        var a = all[player.uid] ?? .present
        change(&a)
        all[player.uid] = a
        game.availability = all
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { availability.present }, set: { value in update { $0.present = value } })) {
                Text(player.name).frame(width: 160, alignment: .leading)
            }
            .toggleStyle(.checkbox)
            if availability.present {
                Picker("Arrives", selection: Binding(get: { availability.arrivesInning ?? 1 }, set: { value in update { $0.arrivesInning = value == 1 ? nil : value } })) {
                    Text("On time").tag(1)
                    ForEach(2...max(game.innings, 2), id: \.self) { Text("Inning \($0)").tag($0) }
                }
                .fixedSize()
                Picker("Leaves", selection: Binding(get: { availability.leavesAfterInning ?? game.innings }, set: { value in update { $0.leavesAfterInning = value >= game.innings ? nil : value } })) {
                    ForEach(1..<max(game.innings, 2), id: \.self) { Text("After \($0)").tag($0) }
                    Text("Stays").tag(game.innings)
                }
                .fixedSize()
                TextField("Note for today", text: Binding(get: { availability.note }, set: { value in update { $0.note = value } }), prompt: Text("e.g. sore arm, no pitching"))
                    .textFieldStyle(.roundedBorder)
            } else {
                Text("Not coming").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .controlSize(.small)
        .padding(.vertical, 5)
    }
}

// MARK: - Plan & checks

struct GamePlanView: View {
    let model: GameModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if !model.document.battingRationale.isEmpty {
                    LabeledText(title: "Batting order", text: model.document.battingRationale)
                }
                if !model.document.defenseRationale.isEmpty {
                    LabeledText(title: "Defense", text: model.document.defenseRationale)
                }
                ForEach(model.document.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if let generated = model.document.generatedAt {
                    Text("Generated \(generated.formatted(date: .abbreviated, time: .shortened)) with \(model.document.model). Hover a name or inning for the AI's reasoning.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Game Plan", systemImage: "sparkles")
        }
    }
}

struct LabeledText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }
}

/// Compliance as computed by the app — not the AI's self-report.
struct ChecksView: View {
    let model: GameModel

    var body: some View {
        let findings = model.findings
        let violations = findings.violations
        let rules = model.context.activeRules
        let checked = rules.filter { $0.check != nil }
        let judgment = rules.filter { $0.check == nil }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if violations.isEmpty {
                    Label(model.hasDefense ? "Lineup verified" : "Batting order verified", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.callout.weight(.semibold))
                    Text(model.hasDefense
                         ? "All 9 positions every inning, nobody in two places, everyone accounted for, eligibility, locks and the pitcher re-entry rule — checked by the app."
                         : "Everyone here bats exactly once.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("\(violations.count) problem\(violations.count == 1 ? "" : "s")", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red).font(.callout.weight(.semibold))
                    ForEach(violations) { finding in
                        Text(finding.message).font(.callout)
                    }
                }

                if !checked.isEmpty && model.hasDefense {
                    Divider()
                    Text("Checked by the app").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(checked) { rule in
                        let failed = violations.contains { $0.ruleID == rule.id }
                        Label(rule.text, systemImage: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed ? .red : .green)
                            .font(.callout)
                    }
                }

                if !judgment.isEmpty && model.hasDefense {
                    Divider()
                    Text("AI judgment (not verified by the app)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(judgment) { rule in
                        let note = model.document.aiRuleNotes.first { $0.rule.localizedCaseInsensitiveContains(rule.text.prefix(25)) || rule.text.localizedCaseInsensitiveContains($0.rule.prefix(25)) }
                        VStack(alignment: .leading, spacing: 2) {
                            Label(rule.text, systemImage: "sparkles").font(.callout)
                            if let note, !note.details.isEmpty {
                                Text("AI: \(note.details)").font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                            }
                        }
                    }
                }

                if model.document.appAdjustedCount > 0 {
                    Divider()
                    Label("The AI couldn't fix every problem after \(model.document.revisions) tries, so the app changed \(model.document.appAdjustedCount) cell\(model.document.appAdjustedCount == 1 ? "" : "s") (outlined in orange).", systemImage: "wrench.adjustable")
                        .font(.caption).foregroundStyle(.orange)
                } else if model.document.revisions > 0 {
                    Text("The AI fixed \(model.document.revisions == 1 ? "a rule problem" : "rule problems") after the app's check.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Checks", systemImage: "checklist")
        }
    }
}
