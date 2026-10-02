import SwiftUI
import SwiftData

enum SidebarSection: String, CaseIterable, Identifiable {
    case games, roster, rules, stats
    var id: String { rawValue }

    var title: String {
        switch self {
        case .games: "Games"
        case .roster: "Roster"
        case .rules: "Rules"
        case .stats: "Stats"
        }
    }

    var symbol: String {
        switch self {
        case .games: "calendar"
        case .roster: "person.3"
        case .rules: "list.bullet.clipboard"
        case .stats: "chart.bar.xaxis"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @AppStorage("selectedTeam") private var selectedTeamID = ""
    @State private var section: SidebarSection? = .games
    @State private var selectedGame: Game?
    @State private var selectedPlayer: Player?
    @State private var selectedRuleSet: RuleSet?
    @State private var showingNewTeam = false

    private var team: Team? {
        teams.first { $0.uid.uuidString == selectedTeamID } ?? teams.first
    }

    var body: some View {
        Group {
            if let team {
                NavigationSplitView {
                    sidebar(team)
                } content: {
                    content(team)
                } detail: {
                    detail(team)
                }
            } else {
                WelcomeView { created in selectedTeamID = created.uid.uuidString }
            }
        }
        .task {
            #if DEBUG
            if let seeded = DebugSupport.seedIfRequested(teams: teams, context: context) {
                selectedTeamID = seeded.uid.uuidString
                selectedGame = seeded.games.first
            } else if DebugSupport.seedSample, selectedGame == nil {
                selectedGame = team?.games.sorted { $0.date < $1.date }.last
            }
            #endif
        }
        .sheet(isPresented: $showingNewTeam) {
            TeamSheet(team: nil) { created in
                selectedTeamID = created.uid.uuidString
                resetSelection()
            }
        }
    }

    private func resetSelection() {
        selectedGame = nil
        selectedPlayer = nil
        selectedRuleSet = nil
    }

    private func sidebar(_ team: Team) -> some View {
        List(selection: $section) {
            ForEach(SidebarSection.allCases) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        .safeAreaInset(edge: .top) {
            Menu {
                ForEach(teams) { t in
                    Button {
                        selectedTeamID = t.uid.uuidString
                        resetSelection()
                    } label: {
                        if t.uid == team.uid { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
                Divider()
                Button("New Team…") { showingNewTeam = true }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(team.name).font(.headline).lineLimit(1)
                        if !team.ageGroup.isEmpty {
                            Text(team.ageGroup).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func content(_ team: Team) -> some View {
        switch section ?? .games {
        case .games: GamesListView(team: team, selection: $selectedGame)
        case .roster: RosterListView(team: team, selection: $selectedPlayer)
        case .rules: RuleSetsListView(team: team, selection: $selectedRuleSet)
        case .stats: StatsListView(team: team)
        }
    }

    @ViewBuilder
    private func detail(_ team: Team) -> some View {
        switch section ?? .games {
        case .games:
            if let selectedGame, selectedGame.team?.uid == team.uid {
                GameDetailView(game: selectedGame).id(selectedGame.persistentModelID)
            } else {
                ContentUnavailableView("No Game Selected", systemImage: "calendar", description: Text("Pick a game, or press ⌘N to add one."))
            }
        case .roster:
            if let selectedPlayer, selectedPlayer.team?.uid == team.uid {
                PlayerEditorView(player: selectedPlayer).id(selectedPlayer.persistentModelID)
            } else {
                ContentUnavailableView("No Player Selected", systemImage: "person", description: Text("Pick a player to edit positions, ratings and notes."))
            }
        case .rules:
            if let selectedRuleSet, selectedRuleSet.team?.uid == team.uid {
                RuleSetEditorView(ruleSet: selectedRuleSet).id(selectedRuleSet.persistentModelID)
            } else {
                ContentUnavailableView("No Rule Set Selected", systemImage: "list.bullet.clipboard", description: Text("Rule sets hold the rules for a kind of game: league, tournament, practice."))
            }
        case .stats:
            ImportStatsView(team: team)
        }
    }
}
