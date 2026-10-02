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
        let best = profile.strengths.filter { profile[$0] >= .good }.prefix(3).map(\.label)
        return best.isEmpty ? "" : "Best at " + best.joined(separator: ", ")
    }
}

struct PlayerEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var player: Player
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header

                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle("Positions")
                        FieldPositions(profile: Binding(get: { player.profile }, set: { player.profile = $0 }))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle("Notes")
                        TextField("What the stats don't show", text: $player.notes, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(5...12)
                            .padding(12)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .help("The AI reads these when it makes the lineup.")
                    }
                    .frame(maxWidth: 360)
                }

                if let stats = player.stats {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle("Season")
                        StatTiles(stats: stats)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Ratings")
                    RatingsGrid(player: player)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            Menu {
                Button(player.active ? "Mark Inactive" : "Mark Active") { player.active.toggle() }
                Divider()
                Button("Delete Player…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        .confirmationDialog("Delete \(player.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { context.delete(player) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("#", text: $player.jersey)
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.bold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
            TextField("Name", text: $player.name)
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.bold))
            if !player.active {
                Text("Inactive")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
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

/// Positions on a field. Tap to cycle: doesn't play → plays → best → doesn't play.
/// (Stored as the position profile: Can't / Can / Primary.)
struct FieldPositions: View {
    @Binding var profile: PositionProfile

    private static let spots: [(Position, CGPoint)] = [
        (.lf, CGPoint(x: 0.14, y: 0.20)), (.cf, CGPoint(x: 0.50, y: 0.08)), (.rf, CGPoint(x: 0.86, y: 0.20)),
        (.ss, CGPoint(x: 0.34, y: 0.43)), (.second, CGPoint(x: 0.66, y: 0.43)),
        (.third, CGPoint(x: 0.20, y: 0.63)), (.p, CGPoint(x: 0.50, y: 0.63)), (.first, CGPoint(x: 0.80, y: 0.63)),
        (.c, CGPoint(x: 0.50, y: 0.92)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    FieldLines().stroke(Color.primary.opacity(0.12), lineWidth: 1.5)
                    ForEach(Self.spots, id: \.0) { position, point in
                        marker(position)
                            .position(x: point.x * size.width, y: point.y * size.height)
                    }
                }
            }
            .frame(width: 300, height: 250)

            HStack(spacing: 14) {
                legend(.cant, "Doesn't play")
                legend(.can, "Plays")
                legend(.primary, "Best")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func marker(_ position: Position) -> some View {
        let fit = profile[position]
        return Button {
            profile[position] = switch fit {
            case .cant: .can
            case .can: .primary
            case .good, .primary: .cant
            }
        } label: {
            Dot(fit: fit, label: position.label, size: 46)
        }
        .buttonStyle(.plain)
        .help("\(position.label): \(fit == .cant ? "doesn't play" : fit == .can ? "plays" : "best") — click to change")
        .contextMenu {
            Button("Doesn't Play") { profile[position] = .cant }
            Button("Plays") { profile[position] = .can }
            Button("Best") { profile[position] = .primary }
        }
    }

    private func legend(_ fit: Fit, _ text: String) -> some View {
        HStack(spacing: 5) {
            Dot(fit: fit, label: "", size: 12)
            Text(text)
        }
    }

    struct Dot: View {
        let fit: Fit
        let label: String
        let size: CGFloat

        var body: some View {
            ZStack {
                switch fit {
                case .cant:
                    Circle().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                case .can:
                    Circle().fill(Color.primary.opacity(0.14))
                case .good, .primary:
                    Circle().fill(Color.accentColor)
                }
                if !label.isEmpty {
                    Text(label)
                        .font(.callout.weight(fit >= .good ? .bold : .medium))
                        .foregroundStyle(fit >= .good ? AnyShapeStyle(Color.white) : fit == .can ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
                if fit >= .good && size > 20 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .offset(y: -size * 0.32)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
    }
}

/// Faint diamond and outfield arc behind the position markers.
nonisolated struct FieldLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let home = CGPoint(x: rect.midX, y: rect.height * 0.92)
        let first = CGPoint(x: rect.width * 0.80, y: rect.height * 0.63)
        let second = CGPoint(x: rect.midX, y: rect.height * 0.36)
        let third = CGPoint(x: rect.width * 0.20, y: rect.height * 0.63)
        path.move(to: home); path.addLine(to: first); path.addLine(to: second); path.addLine(to: third); path.closeSubpath()
        // Foul lines run straight from home plate through first and third to the fence.
        func extend(through base: CGPoint, toX x: CGFloat) -> CGPoint {
            let t = (x - home.x) / (base.x - home.x)
            return CGPoint(x: x, y: home.y + t * (base.y - home.y))
        }
        let leftFoul = extend(through: third, toX: rect.width * 0.01)
        let rightFoul = extend(through: first, toX: rect.width * 0.99)
        path.move(to: third); path.addLine(to: leftFoul)
        path.move(to: first); path.addLine(to: rightFoul)
        // Outfield fence: a quad curve whose top sits just above center field.
        let apexY = rect.height * 0.0
        let control = CGPoint(x: rect.midX, y: 2 * apexY - (leftFoul.y + rightFoul.y) / 2)
        path.move(to: leftFoul)
        path.addQuadCurve(to: rightFoul, control: control)
        return path
    }
}

/// Ratings grouped by kind; pitching and catching only show for players who do those.
struct RatingsGrid: View {
    @Bindable var player: Player

    var body: some View {
        let profile = player.profile
        let groups = RatingKey.Group.allCases.filter { group in
            switch group {
            case .pitching: profile.canPlay(.p)
            case .catching: profile.canPlay(.c)
            default: true
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .topLeading)], alignment: .leading, spacing: 24) {
            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.rawValue.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(RatingKey.allCases.filter { $0.group == group }, id: \.self) { key in
                        HStack {
                            Text(key.label)
                            Spacer()
                            StarRating(value: Binding(
                                get: { player.ratings[key] },
                                set: { var r = player.ratings; r[key] = $0; player.ratings = r }
                            ))
                        }
                        .frame(maxWidth: 250)
                    }
                }
            }
        }
    }
}

/// Season numbers as big, scannable tiles, one labeled row per kind.
struct StatTiles: View {
    let stats: PlayerStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let b = stats.batting, b.pa > 0 {
                row("Hitting", [(Fmt.rate(b.avg), "AVG"), (Fmt.rate(b.obp), "OBP"), (Fmt.rate(b.slg), "SLG"),
                                (Fmt.pct(b.kRate), "K%"), (Fmt.pct(b.bbRate), "BB%"), ("\(b.sb)", "SB"), ("\(b.pa)", "PA")])
            }
            if let f = stats.fielding, f.tc > 0 || f.catcherOuts > 0 {
                row("Fielding", [(Fmt.rate(f.fpct), "FPCT"), ("\(f.e)", "E")]
                    + (f.catcherOuts > 0 ? [("\(f.catcherOuts / 3).\(f.catcherOuts % 3)", "INN CAUGHT")] : []))
            }
            if let p = stats.pitching, p.outs > 0 {
                row("Pitching", [(p.ipText, "IP"), (Fmt.two(p.era), "ERA"), (Fmt.two(p.whip), "WHIP"), ("\(p.so)", "K"), ("\(p.bb)", "BB")])
            }
        }
    }

    private func row(_ title: String, _ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 2) {
                        Text(item.0).font(.title3.weight(.semibold).monospacedDigit())
                        Text(item.1).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 64)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
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

enum Fmt {
    static func rate(_ v: Double?) -> String {
        guard let v else { return "–" }
        let s = String(format: "%.3f", v)
        return s.hasPrefix("0.") ? String(s.dropFirst()) : s
    }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0 * 100) } ?? "–" }
    static func two(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
}
