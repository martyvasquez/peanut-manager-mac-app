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
    @State private var navigator = Navigator.shared
    private var section: SidebarSection? { navigator.section }
    @State private var selectedGame: Game?
    @State private var selectedPlayer: Player?
    @State private var selectedRuleSet: RuleSet?
    @State private var showingNewTeam = false
    @State private var editingTeam: Team?
    @State private var deletingTeam: Team?
    @Environment(\.openSettings) private var openSettings

    private var team: Team? {
        teams.first { $0.uid.uuidString == selectedTeamID } ?? teams.first
    }

    var body: some View {
        Group {
            if let team {
                if section == .stats {
                    // Stats is one full-width page, not a list + detail.
                    NavigationSplitView {
                        sidebar(team)
                    } detail: {
                        StatsView(team: team)
                    }
                } else {
                    NavigationSplitView {
                        sidebar(team)
                    } content: {
                        content(team)
                    } detail: {
                        detail(team)
                    }
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
            if UserDefaults.standard.bool(forKey: "PMOpenSettings") { openSettings() }
            if let open = UserDefaults.standard.string(forKey: "PMSection"), let target = SidebarSection(rawValue: open) {
                navigator.section = target
                selectedPlayer = team?.activePlayers.dropFirst(7).first
                selectedRuleSet = team?.sortedRuleSets.first
            }
            #endif
        }
        .sheet(item: $editingTeam) { team in
            TeamSheet(team: team)
        }
        .confirmationDialog("Delete \(deletingTeam?.name ?? "team")?", isPresented: Binding(get: { deletingTeam != nil }, set: { if !$0 { deletingTeam = nil } })) {
            Button("Delete Team", role: .destructive) {
                if let team = deletingTeam {
                    resetSelection()
                    context.delete(team)
                    selectedTeamID = teams.first { $0.uid != team.uid }?.uid.uuidString ?? ""
                }
                deletingTeam = nil
            }
        } message: {
            Text("Its players, rules and games are deleted too. This can't be undone.")
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
        List(selection: $navigator.section) {
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
                Button("Edit \(team.name)…") { editingTeam = team }
                Button("Delete \(team.name)…", role: .destructive) { deletingTeam = team }
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
        case .stats: EmptyView()
        }
    }

    @ViewBuilder
    private func detail(_ team: Team) -> some View {
        switch section ?? .games {
        case .games:
            if let selectedGame, selectedGame.team?.uid == team.uid {
                GameDetailView(game: selectedGame).id(selectedGame.persistentModelID)
            } else {
                ContentUnavailableView("No Game Selected", systemImage: "calendar")
            }
        case .roster:
            if let selectedPlayer, selectedPlayer.team?.uid == team.uid {
                PlayerEditorView(player: selectedPlayer).id(selectedPlayer.persistentModelID)
            } else {
                ContentUnavailableView("No Player Selected", systemImage: "person")
            }
        case .rules:
            if let selectedRuleSet, selectedRuleSet.team?.uid == team.uid {
                RuleSetEditorView(ruleSet: selectedRuleSet).id(selectedRuleSet.persistentModelID)
            } else {
                ContentUnavailableView("No Rules Selected", systemImage: "list.bullet.clipboard")
            }
        case .stats:
            EmptyView()
        }
    }
}
