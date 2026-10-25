import SwiftUI
import SwiftData
import LineupKit

/// The app: Games, Roster and Rules for the current team. The team's name titles Games; tap it to switch teams,
/// add one, or edit this one. With no teams yet, the welcome screen.
struct HomeView: View {
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @Environment(\.modelContext) private var context
    @AppStorage("phoneTeam") private var teamID = ""
    @Bindable private var navigator = Navigator.shared
    @State private var path: [Game] = []
    @Bindable private var ai = AIService.shared
    @State private var showsSettings = false
    @State private var newTeam = false
    @State private var editingTeam: Team?

    private var team: Team? { teams.first { $0.uid.uuidString == teamID } ?? teams.first }

    var body: some View {
        Group {
            if let team {
                TabView(selection: Binding(get: { navigator.section ?? .games }, set: { navigator.section = $0 })) {
                    Tab("Games", systemImage: "calendar", value: .games) {
                        NavigationStack(path: $path) {
                            GamesList(team: team, path: $path)
                                .navigationTitle(team.name)
                                .toolbarTitleMenu { teamMenu(team) }
                                .navigationDestination(for: Game.self) { GameScreen(game: $0) }
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                                    }
                                }
                        }
                    }
                    Tab("Roster", systemImage: "person.3", value: .roster) {
                        RosterList(team: team)
                    }
                    Tab("Insights", systemImage: "chart.bar.xaxis", value: .insights) {
                        NavigationStack { StatsInsightsView(team: team) }
                    }
                    Tab("Rules", systemImage: "list.bullet.clipboard", value: .rules) {
                        RuleSetsList(team: team)
                    }
                }
                // Each team keeps its own place.
                .id(team.persistentModelID)
            } else if CloudSync.shared.isLookingInICloud {
                // A new phone downloading the library: wait here rather than offer New Team and make a duplicate.
                ICloudWaitView()
            } else {
                WelcomeView(onCreate: { teamID = $0.uid.uuidString }, newTeam: $newTeam, loadSample: { loadSample() })
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsScreen() }
        .sheet(isPresented: $newTeam) { TeamSheet(team: nil) { teamID = $0.uid.uuidString } }
        .sheet(item: $editingTeam) { TeamSheet(team: $0) }
        .sheet(item: $ai.consentRequest, onDismiss: { ai.consentSheetClosed() }) { request in
            ConsentSheet(request: request)
        }
        .task(debugSetup)
    }

    @ViewBuilder
    private func teamMenu(_ current: Team) -> some View {
        if teams.count > 1 {
            Picker("Team", selection: Binding(get: { current.uid.uuidString }, set: { teamID = $0 })) {
                ForEach(teams) { Text($0.name).tag($0.uid.uuidString) }
            }
        }
        Button("Edit \(current.name)…", systemImage: "pencil") { editingTeam = current }
        Button("New Team…", systemImage: "plus") { newTeam = true }
    }

    @discardableResult
    private func loadSample() -> Team? {
        guard let sample = try? SampleData.makeTeam(in: context) else { return nil }
        teamID = sample.uid.uuidString
        return sample
    }

    private func debugSetup() {
        #if DEBUG
        let defaults = UserDefaults.standard
        // The query hasn't seen a team made just now, so use it directly.
        let seeded = DebugSupport.seedSample && teams.isEmpty ? loadSample() : nil
        // `-PMEmptyTeam YES` makes a team with no players yet.
        if defaults.bool(forKey: "PMEmptyTeam"), teams.isEmpty {
            let team = Team(name: "Trojans", ageGroup: "10U")
            context.insert(team)
            SampleData.addStarterRules(to: team, in: context)
            teamID = team.uid.uuidString
        }
        // `-PMTab roster|rules` opens that tab.
        switch defaults.string(forKey: "PMTab") {
        case "roster": navigator.section = .roster
        case "rules": navigator.section = .rules
        case "insights": navigator.section = .insights
        default: break
        }
        // `-PMAddGame YES` adds a game a week after the last one, with the sixth player out, and opens it.
        if defaults.bool(forKey: "PMAddGame"), let team = seeded ?? team,
           let last = team.games.max(by: { $0.date < $1.date }) {
            let game = Game(opponent: "Tigers", date: last.date.addingTimeInterval(7 * 86_400), innings: last.innings)
            context.insert(game)
            game.team = team
            game.ruleSet = last.ruleSet
            if let out = team.activePlayers.dropFirst(5).first { game.availability = [out.uid: .absent] }
            path = [game]
            return
        }
        // `-PMSettings YES` opens Settings, for screenshots.
        if defaults.bool(forKey: "PMSettings") { showsSettings = true }
        // `-PMSignIn YES` starts Sign in with ChatGPT, to check OpenAI's page opens in the app.
        if defaults.bool(forKey: "PMSignIn") { AIService.shared.signIn() }
        // `-PMOpenGame YES` opens the team's next game, for screenshots.
        if defaults.bool(forKey: "PMOpenGame"), let game = ((seeded ?? team)?.games ?? []).max(by: { $0.date < $1.date }) {
            path = [game]
        }
        #endif
    }
}

struct GamesList: View {
    let team: Team
    @Binding var path: [Game]
    @Environment(\.modelContext) private var context
    @State private var addingGame = false
    @State private var deleting: Game?
    @State private var importing = false

    var body: some View {
        let games = team.games.sorted { $0.date < $1.date }
        let upcoming = games.filter { !$0.isPast }
        let past = Array(games.filter(\.isPast).reversed())
        List {
            if !upcoming.isEmpty {
                Section("Upcoming") { ForEach(upcoming, content: row) }
            }
            if !past.isEmpty {
                Section("Past") { ForEach(past, content: row) }
            }
        }
        .overlay {
            // A game needs kids: no roster, no new games.
            if team.activePlayers.isEmpty && games.isEmpty {
                ContentUnavailableView {
                    Label("No Players Yet", systemImage: "person.3")
                } description: {
                    Text("Add your team first.")
                } actions: {
                    Button("Import from GameChanger") { importing = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if games.isEmpty {
                ContentUnavailableView {
                    Label("No Games", systemImage: "calendar")
                } actions: {
                    Button("New Game") { addingGame = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Game", systemImage: "plus") { addingGame = true }
                    .disabled(team.activePlayers.isEmpty)
            }
        }
        .gameChangerImport(team: team, isPresented: $importing)
        .sheet(isPresented: $addingGame) {
            NewGameSheet(team: team) { path.append($0) }
        }
        .confirmationDialog("Delete \(deleting?.opponent ?? "this game")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Game", role: .destructive) {
                if let deleting { context.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Its lineup goes too.")
        }
    }

    private func row(_ game: Game) -> some View {
        NavigationLink(value: game) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.opponent.isEmpty ? "Game" : game.opponent).font(.body.weight(.medium))
                    Text(game.date, format: .dateTime.weekday(.wide).month().day())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                // A finished lineup, as on the Mac.
                if let lineup = game.document?.lineup, lineup.hasDefense, lineup.isFullyPositioned || game.document?.generatedAt != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = game }
        }
    }
}

/// Opponent and date; everything else carries over from the last game, so the common path is two fields and Add.
/// The same rules as the Mac's `NewGameSheet`.
struct NewGameSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let team: Team
    var onCreate: (Game) -> Void
    @State private var opponent = ""
    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Opponent", text: $opponent)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if canAdd { add() } }
                DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
            }
            .navigationTitle("New Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(!canAdd)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }

    private var canAdd: Bool { !opponent.trimmingCharacters(in: .whitespaces).isEmpty }

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
        dismiss()
        onCreate(game)
    }
}
