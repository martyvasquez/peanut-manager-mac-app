import SwiftUI
import SwiftData
import LineupKit

/// Everything about the game that isn't the lineup: who's coming, innings, rules, and what the AI should know.
/// The Mac keeps these as chips over the lineup; a phone has no room, so they live here.
struct GameSetupSheet: View {
    @Bindable var game: Game
    let model: GameModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let players = game.team?.activePlayers ?? []
        let coming = players.filter { (game.availability[$0.uid] ?? .present).present }.count
        let ai = AIService.shared
        NavigationStack {
            Form {
                Section {
                    TextField("Opponent", text: $game.opponent)
                    DatePicker("Date", selection: $game.date, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    NavigationLink {
                        AttendanceList(game: game)
                    } label: {
                        LabeledContent("Who's Coming") {
                            Text(coming == players.count ? "Everyone" : "\(coming) of \(players.count)")
                                .foregroundStyle(coming < 9 ? .red : .secondary)
                        }
                    }
                    Stepper(value: innings, in: 1...12) {
                        LabeledContent("Innings", value: "\(game.innings)")
                    }
                    // Selects by ID: in clean builds the compiler doesn't always see @Model's Hashable conformance here.
                    Picker("Rules", selection: Binding(
                        get: { game.ruleSet?.persistentModelID },
                        set: { id in game.ruleSet = game.team?.ruleSets.first { $0.persistentModelID == id } }
                    )) {
                        Text("No Rules").tag(PersistentIdentifier?.none)
                        ForEach(game.team?.sortedRuleSets ?? []) { Text($0.name).tag(Optional($0.persistentModelID)) }
                    }
                } footer: {
                    if coming < 9 { Text("Only \(coming) coming. You need 9 to field a team.").foregroundStyle(.red) }
                }
                if ai.isReady {
                    Section {
                        Picker("Priority", selection: Binding(get: { game.priority }, set: { game.priority = $0 })) {
                            ForEach(GamePriority.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        if game.hasStats {
                            Picker("Trust", selection: Binding(get: { game.weighting }, set: { game.weighting = $0 })) {
                                ForEach(DataWeighting.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                        } else {
                            LabeledContent("Trust", value: DataWeighting.coachOnly.label)
                        }
                        TextField("Notes", text: $game.notesForAI, prompt: Text("Cole pitches the 1st and 2nd"), axis: .vertical)
                            .lineLimit(2...6)
                    } header: {
                        Text("For the AI")
                    } footer: {
                        if !game.hasStats { Text("No stats yet, so the AI goes by your ratings.") }
                    }
                }
                Section {
                    TextField("Scouting Report", text: $game.scoutingReport, prompt: Text("They bunt a lot"), axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text(game.opponent.isEmpty ? "Scouting Report" : "Scouting Report on \(game.opponent)")
                } footer: {
                    Text("Carries over the next time you play them.")
                }
            }
            .navigationTitle("Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// Innings change through the game model once there's a grid, so locks and notes move with their innings
    /// and undo puts them back.
    private var innings: Binding<Int> {
        Binding(
            get: { game.innings },
            set: { count in
                guard model.hasGrid else { game.innings = count; return }
                while game.innings < count { model.insertInning(at: game.innings + 1, undoManager: undoManager) }
                while game.innings > count, game.innings > 1 { model.removeInning(game.innings, undoManager: undoManager) }
            }
        )
    }
}

/// Who's coming: one check per kid.
struct AttendanceList: View {
    @Bindable var game: Game

    var body: some View {
        let players = game.team?.activePlayers ?? []
        let coming = players.filter(isComing).count
        List {
            Section {
                ForEach(players) { player in
                    let on = isComing(player)
                    Button { set(player, coming: !on) } label: {
                        HStack {
                            Text(player.name).foregroundStyle(on ? .primary : .secondary)
                            Spacer()
                            if on {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            } else {
                                Text("Out").foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if coming < 9 { Text("Only \(coming) coming. You need 9 to field a team.").foregroundStyle(.red) }
            }
        }
        .navigationTitle("Who's Coming")
        .toolbar {
            if coming < players.count {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Everyone") { game.availability = [:] }
                }
            }
        }
    }

    private func isComing(_ player: Player) -> Bool { (game.availability[player.uid] ?? .present).present }

    private func set(_ player: Player, coming: Bool) {
        var all = game.availability
        all[player.uid] = coming ? nil : .absent
        game.availability = all
    }
}
