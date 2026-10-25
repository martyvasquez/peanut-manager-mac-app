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

    private var team: Team? { teams.first { $0.uid.uuidString == teamID } ?? teams.first }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let team {
                    GamesList(team: team)
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
        }
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
        // `-PMOpenGame YES` opens the team's next game, for screenshots.
        if UserDefaults.standard.bool(forKey: "PMOpenGame"), let game = ((seeded ?? team)?.games ?? []).max(by: { $0.date < $1.date }) {
            path = [game]
        }
        #endif
    }
}

struct GamesList: View {
    let team: Team

    var body: some View {
        let games = team.games.sorted { $0.date > $1.date }
        List(games) { game in
            NavigationLink(value: game) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.opponent.isEmpty ? "Game" : game.opponent).font(.body.weight(.medium))
                    Text(game.date, format: .dateTime.weekday(.wide).month().day())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .overlay {
            if games.isEmpty { ContentUnavailableView("No Games Yet", systemImage: "calendar") }
        }
    }
}
