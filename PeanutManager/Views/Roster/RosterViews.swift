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
                    Text("Or import a GameChanger export from Stats.")
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
                if !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()

        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let profile = player.profile
        return profile.strengths.filter { profile[$0] >= .good }.prefix(3).map(\.label).joined(separator: " · ")
    }
}

struct PlayerEditorView: View {
    @Bindable var player: Player

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        TextField("#", text: $player.jersey)
                            .textFieldStyle(.plain)
                            .font(.largeTitle.weight(.bold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                        TextField("Name", text: $player.name)
                            .textFieldStyle(.plain)
                            .font(.largeTitle.weight(.bold))
                    }
                    TextField("Notes", text: $player.notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.secondary)
                        .lineLimit(1...8)
                        .help("What the stats don't show. The AI reads these.")
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Positions")
                    PositionChips(profile: Binding(get: { player.profile }, set: { player.profile = $0 }))
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Ratings")
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        ForEach(RatingKey.allCases, id: \.self) { key in
                            GridRow {
                                Text(key.label).foregroundStyle(.secondary)
                                StarRating(value: Binding(
                                    get: { player.ratings[key] },
                                    set: { var r = player.ratings; r[key] = $0; player.ratings = r }
                                ))
                            }
                        }
                    }
                }

                if let stats = player.stats {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Stats")
                        StatsSummary(stats: stats)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            Toggle(isOn: Binding(get: { !player.active }, set: { player.active = !$0 })) {
                Label("Inactive", systemImage: "moon.zzz")
            }
            .help(player.active ? "Mark inactive" : "Inactive — not on game rosters")
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline)
    }
}

/// One chip per position. Click to cycle Can → Good → Primary → Can't.
struct PositionChips: View {
    @Binding var profile: PositionProfile

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Position.allCases, id: \.self) { position in
                let fit = profile[position]
                Button { profile[position] = next(fit) } label: {
                    Text(position.label)
                        .font(.callout.weight(fit >= .good ? .semibold : .regular))
                        .strikethrough(fit == .cant)
                        .frame(width: 38, height: 28)
                        .foregroundStyle(foreground(fit))
                        .background(background(fit), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(fit == .good ? Color.accentColor.opacity(0.7) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(position.label): \(fit.label)")
                .contextMenu {
                    ForEach(Fit.allCases.reversed(), id: \.self) { option in
                        Button(option.label) { profile[position] = option }
                    }
                }
            }
        }
    }

    private func next(_ fit: Fit) -> Fit {
        switch fit {
        case .can: .good
        case .good: .primary
        case .primary: .cant
        case .cant: .can
        }
    }

    private func foreground(_ fit: Fit) -> AnyShapeStyle {
        switch fit {
        case .cant: AnyShapeStyle(.quaternary)
        case .can: AnyShapeStyle(.secondary)
        case .good: AnyShapeStyle(Color.accentColor)
        case .primary: AnyShapeStyle(Color.white)
        }
    }

    private func background(_ fit: Fit) -> AnyShapeStyle {
        switch fit {
        case .cant: AnyShapeStyle(Color.clear)
        case .can: AnyShapeStyle(.quaternary.opacity(0.5))
        case .good: AnyShapeStyle(Color.accentColor.opacity(0.08))
        case .primary: AnyShapeStyle(Color.accentColor)
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
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(star <= (hover ?? value ?? 0) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .onHover { inside in hover = inside ? star : nil }
                    .onTapGesture { value = value == star ? nil : star }
            }
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
        VStack(alignment: .leading, spacing: 4) {
            if let b = stats.batting, b.pa > 0 {
                Text("\(Fmt.rate(b.avg)) / \(Fmt.rate(b.obp)) / \(Fmt.rate(b.slg))  ·  \(b.pa) PA  ·  \(Fmt.pct(b.kRate)) K  ·  \(Fmt.pct(b.bbRate)) BB  ·  \(b.sb) SB")
            }
            if let f = stats.fielding, f.tc > 0 {
                Text("\(Fmt.rate(f.fpct)) fielding  ·  \(f.e) E")
            }
            if let p = stats.pitching, p.outs > 0 {
                Text("\(String(format: "%.1f", p.innings)) IP  ·  \(Fmt.two(p.era)) ERA  ·  \(p.so) K  ·  \(p.bb) BB")
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
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
