import SwiftUI
import SwiftData
import LineupKit

/// The team's games, newest first. A coach with more than one team switches from the title menu.
struct HomeView: View {
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @Environment(\.modelContext) private var context
    @AppStorage("phoneTeam") private var teamID = ""
    @State private var path: [Game] = []
    @Bindable private var ai = AIService.shared
    @State private var showsSettings = false

    private var team: Team? { teams.first { $0.uid.uuidString == teamID } ?? teams.first }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let team {
                    GamesList(team: team, path: $path)
                } else {
                    ContentUnavailableView {
                        Label("No Teams Yet", systemImage: "figure.baseball")
                    } actions: {
                        Button("Try a Sample") { loadSample() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(team?.name ?? "Peanut Manager")
            .toolbarTitleMenu {
                if teams.count > 1 {
                    ForEach(teams) { t in
                        Button(t.name) { teamID = t.uid.uuidString }
                    }
                }
            }
            .navigationDestination(for: Game.self) { GameScreen(game: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsScreen() }
        .sheet(item: $ai.consentRequest, onDismiss: { ai.consentSheetClosed() }) { request in
            ConsentSheet(request: request)
        }
        .task(debugSetup)
    }

    @discardableResult
    private func loadSample() -> Team? {
        guard let sample = try? SampleData.makeTeam(in: context) else { return nil }
        teamID = sample.uid.uuidString
        return sample
    }

    private func debugSetup() {
        #if DEBUG
        // The query hasn't seen a team made just now, so use it directly.
        let seeded = DebugSupport.seedSample && teams.isEmpty ? loadSample() : nil
        // `-PMAddGame YES` adds a game a week after the last one, with the sixth player out, and opens it.
        if UserDefaults.standard.bool(forKey: "PMAddGame"), let team = seeded ?? team,
           let last = team.games.max(by: { $0.date < $1.date }) {
            let game = Game(opponent: "Tigers", date: last.date.addingTimeInterval(7 * 86_400), innings: last.innings)
            context.insert(game)
            game.team = team
            game.ruleSet = last.ruleSet
            if let out = team.activePlayers.dropFirst(5).first { game.availability = [out.uid: .absent] }
            path = [game]
            return
        }
        // `-PMOpenGame YES` opens the team's next game, for screenshots.
        // `-PMSettings YES` opens Settings, for screenshots.
        if UserDefaults.standard.bool(forKey: "PMSettings") { showsSettings = true }
        // `-PMSignIn YES` starts Sign in with ChatGPT, to check OpenAI's page opens in the app.
        if UserDefaults.standard.bool(forKey: "PMSignIn") { AIService.shared.signIn() }
        if UserDefaults.standard.bool(forKey: "PMOpenGame"), let game = ((seeded ?? team)?.games ?? []).max(by: { $0.date < $1.date }) {
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
                ContentUnavailableView("No Players Yet", systemImage: "person.3", description: Text("Add your team first."))
            } else if games.isEmpty {
                ContentUnavailableView {
                    Label("No Games", systemImage: "calendar")
                } actions: {
                    Button("New Game") { addingGame = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("New Game", systemImage: "plus") { addingGame = true }
                    .disabled(team.activePlayers.isEmpty)
            }
        }
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
