import SwiftUI
import SwiftData
import LineupKit

/// First launch: create a team, or explore with the bundled sample team.
struct WelcomeView: View {
    @Environment(\.modelContext) private var context
    var onCreate: (Team) -> Void
    @State private var showingNewTeam = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "baseball")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Peanut Manager").font(.largeTitle.weight(.semibold))
            Text("Lineups in minutes.")
                .font(.title3)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("New Team") { showingNewTeam = true }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                Button("Try a Sample") { loadSample() }
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingNewTeam) {
            TeamSheet(team: nil, onCreate: onCreate)
        }
    }

    private func loadSample() {
        do {
            let team = try SampleData.makeTeam(in: context)
            onCreate(team)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Create or edit a team.
struct TeamSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var team: Team?
    var onCreate: (Team) -> Void = { _ in }

    @State private var name = ""
    @State private var ageGroup = ""
    @State private var innings = 6

    var body: some View {
        Form {
            TextField("Team Name", text: $name)
            TextField("Age Group", text: $ageGroup, prompt: Text("10U"))
            Picker("Innings", selection: $innings) {
                ForEach([3, 4, 5, 6, 7, 9], id: \.self) { Text("\($0)").tag($0) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
                .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(team == nil ? "Create" : "Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if let team {
                name = team.name
                ageGroup = team.ageGroup
                innings = team.defaultInnings
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let team {
            team.name = trimmed
            team.ageGroup = ageGroup
            team.defaultInnings = innings
        } else {
            let team = Team(name: trimmed, ageGroup: ageGroup, defaultInnings: innings)
            context.insert(team)
            SampleData.addStarterRules(to: team, in: context)
            onCreate(team)
        }
        dismiss()
    }
}

enum SampleData {
    /// v1's shipped example rules, with code checks attached where one fits.
    /// ("Everyone bats" isn't listed: the app always enforces it.)
    static func addStarterRules(to team: Team, in context: ModelContext) {
        let league = RuleSet(name: "League")
        context.insert(league)
        league.team = team
        let rules: [(String, RuleCheck?)] = [
            ("Every player must play at least 3 innings in the field.", .minFieldInnings(3)),
            ("Players must sit out at most 1 inning in a row.", .maxConsecutiveSits(1)),
            ("All players must play an infield position by the end of the 4th inning.", .infieldBy(inning: 4)),
            ("No player can pitch more than 2 innings.", .maxPitchingInnings(2)),
        ]
        for (index, rule) in rules.enumerated() {
            let r = Rule(text: rule.0, order: index, check: rule.1)
            context.insert(r)
            r.ruleSet = league
        }
        let tournament = RuleSet(name: "Tournament")
        context.insert(tournament)
        tournament.team = team
        let t = Rule(text: "Every player must play at least 2 innings in the field.", order: 0, check: .minFieldInnings(2))
        context.insert(t)
        t.ruleSet = tournament
    }

    /// A 12-player team built from the bundled (anonymized) GameChanger export.
    static func makeTeam(in context: ModelContext) throws -> Team {
        guard let url = Bundle.main.url(forResource: "sample-team", withExtension: "csv") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rows = try GameChangerImport.parse(String(contentsOf: url, encoding: .utf8))
        let team = Team(name: "Sample Team", ageGroup: "10U", defaultInnings: 6)
        context.insert(team)
        addStarterRules(to: team, in: context)

        for (index, row) in rows.enumerated() {
            let player = Player(name: row.fullName, jersey: row.number, sortIndex: index)
            context.insert(player)
            player.team = team
            player.stats = PlayerStats(batting: row.batting, fielding: row.fielding, pitching: row.pitching)
            player.applyGameChangerHistory()
        }
        team.statsImportedAt = .now

        let game = Game(opponent: "Sample Opponent", date: Calendar.current.date(byAdding: .day, value: 1, to: .now)!, innings: 6)
        context.insert(game)
        game.team = team
        game.ruleSet = team.sortedRuleSets.first
        return team
    }
}
