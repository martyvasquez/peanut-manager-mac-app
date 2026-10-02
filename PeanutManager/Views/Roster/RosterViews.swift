import SwiftUI
import SwiftData
import LineupKit

struct RosterListView: View {
    @Environment(\.modelContext) private var context
    let team: Team
    @Binding var selection: Player?

    var body: some View {
        List(selection: $selection) {
            ForEach(team.sortedPlayers) { player in
                PlayerRow(player: player).tag(player)
            }
            .onMove(perform: move)
        }
        .navigationTitle("Roster")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        .overlay {
            if team.players.isEmpty {
                ContentUnavailableView {
                    Label("No Players", systemImage: "person.3")
                } description: {
                    Text("Add players one at a time, or import a GameChanger stats export under Stats to create the roster.")
                } actions: {
                    Button("Add Player") { addPlayer() }
                }
            }
        }
        .toolbar {
            Button("Add Player", systemImage: "plus") { addPlayer() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .contextMenu(forSelectionType: Player.self) { players in
            if let player = players.first {
                Button(player.active ? "Mark Inactive" : "Mark Active") { player.active.toggle() }
                Divider()
                Button("Delete", role: .destructive) { delete(player) }
            }
        }
        .onDeleteCommand { if let selection { delete(selection) } }
    }

    private func addPlayer() {
        let player = Player(name: "New Player", sortIndex: (team.players.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(player)
        player.team = team
        selection = player
    }

    private func delete(_ player: Player) {
        if selection == player { selection = nil }
        context.delete(player)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var players = team.sortedPlayers
        players.move(fromOffsets: source, toOffset: destination)
        for (index, player) in players.enumerated() { player.sortIndex = index }
    }
}

struct PlayerRow: View {
    let player: Player

    var body: some View {
        HStack(spacing: 10) {
            Text(player.jersey.isEmpty ? "–" : player.jersey)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.name).foregroundStyle(player.active ? .primary : .secondary)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !player.active {
                Text("Inactive").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let profile = player.profile
        let top = profile.strengths.filter { profile[$0] >= .good }.prefix(3).map(\.label)
        let rated = player.ratings.values.count
        var parts: [String] = []
        if !top.isEmpty { parts.append(top.joined(separator: ", ")) }
        parts.append(rated == 0 ? "Unrated" : "\(rated)/14 rated")
        if player.stats?.batting?.pa ?? 0 > 0 { parts.append("Stats") }
        return parts.joined(separator: " · ")
    }
}

struct PlayerEditorView: View {
    @Bindable var player: Player

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $player.name)
                TextField("Jersey", text: $player.jersey)
                Toggle("Active", isOn: $player.active)
            }

            Section {
                PositionProfileEditor(profile: Binding(get: { player.profile }, set: { player.profile = $0 }))
            } header: {
                Text("Positions")
            } footer: {
                Text("Can't keeps the AI from ever putting them there. Primary is where they're strongest.")
            }

            Section {
                TextEditor(text: $player.notes)
                    .font(.body)
                    .frame(minHeight: 70)
            } header: {
                Text("Coach Notes")
            } footer: {
                Text("What the stats don't show — \"afraid of fly balls,\" \"great teammate, needs reps at 1B.\" The AI reads these.")
            }

            ForEach(RatingKey.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(RatingKey.allCases.filter { $0.group == group }, id: \.self) { key in
                        LabeledContent(key.label) {
                            StarRating(value: Binding(
                                get: { player.ratings[key] },
                                set: { var r = player.ratings; r[key] = $0; player.ratings = r }
                            ))
                        }
                    }
                }
            }

            if let stats = player.stats {
                Section("GameChanger (season)") { StatsSummary(stats: stats) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(player.name)
    }
}

struct PositionProfileEditor: View {
    @Binding var profile: PositionProfile

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Position.allCases, id: \.self) { position in
                GridRow {
                    Text(position.label)
                        .font(.callout.weight(.semibold).monospaced())
                        .frame(width: 28, alignment: .leading)
                    Picker(position.label, selection: Binding(get: { profile[position] }, set: { profile[position] = $0 })) {
                        ForEach(Fit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            GridRow {
                Text("").gridCellUnsizedAxes(.horizontal)
                HStack {
                    Button("All Outfield: Can") { for p in [Position.lf, .cf, .rf] { profile[p] = .can } }
                    Button("Reset") { profile = .default }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

/// 1–5 stars; click the current value again to clear it (unrated).
struct StarRating: View {
    @Binding var value: Int?
    @State private var hover: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= (hover ?? value ?? 0) ? "star.fill" : "star")
                    .foregroundStyle(star <= (hover ?? value ?? 0) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .onHover { inside in hover = inside ? star : nil }
                    .onTapGesture { value = value == star ? nil : star }
            }
            Text(value == nil ? "Unrated" : "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
        }
        .accessibilityElement()
        .accessibilityLabel(value.map { "\($0) stars" } ?? "Unrated")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min((value ?? 0) + 1, 5)
            case .decrement: value = (value ?? 1) <= 1 ? nil : value! - 1
            @unknown default: break
            }
        }
    }
}

struct StatsSummary: View {
    let stats: PlayerStats

    var body: some View {
        if let b = stats.batting, b.pa > 0 {
            LabeledContent("Batting", value: "\(b.pa) PA · \(Fmt.rate(b.avg)) / \(Fmt.rate(b.obp)) / \(Fmt.rate(b.slg)) · K \(Fmt.pct(b.kRate)) · BB \(Fmt.pct(b.bbRate)) · SB \(b.sb)")
        }
        if let f = stats.fielding, f.tc > 0 {
            LabeledContent("Fielding", value: "\(f.tc) TC · FPCT \(Fmt.rate(f.fpct)) · E \(f.e)")
        }
        if let p = stats.pitching, p.outs > 0 {
            LabeledContent("Pitching", value: "\(String(format: "%.1f", p.innings)) IP · ERA \(Fmt.two(p.era)) · WHIP \(Fmt.two(p.whip)) · K \(p.so) · BB \(p.bb)")
        }
        LabeledContent("Imported", value: stats.importedAt.formatted(date: .abbreviated, time: .omitted))
    }
}

enum Fmt {
    static func rate(_ v: Double?) -> String {
        guard let v else { return "–" }
        let s = String(format: "%.3f", v)
        return s.hasPrefix("0.") ? String(s.dropFirst()) : s
    }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0 * 100) } ?? "–" }
    static func two(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
}
