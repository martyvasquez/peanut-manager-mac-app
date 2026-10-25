import SwiftUI
import SwiftData
import LineupKit

/// The team's players, in roster order. Tap one to edit; swipe for inactive or delete; Edit to reorder.
struct RosterList: View {
    @Environment(\.modelContext) private var context
    let team: Team
    @State private var path: [Player] = []
    @State private var deleting: Player?
    @State private var importing = false

    var body: some View {
        NavigationStack(path: $path) { list }
            // A kid opened from elsewhere (an Insights link): show their page, then let it go.
            .onChange(of: Navigator.shared.playerToOpen, initial: true) { _, player in
                guard let player else { return }
                path = [player]
                Navigator.shared.playerToOpen = nil
            }
            #if DEBUG
            // `-PMPlayer Name` opens the first player whose name starts with Name.
            .onAppear {
                if let name = UserDefaults.standard.string(forKey: "PMPlayer"),
                   let player = team.sortedPlayers.first(where: { $0.name.hasPrefix(name) }) { path = [player] }
            }
            #endif
    }

    private var list: some View {
        List {
            ForEach(team.sortedPlayers) { player in
                NavigationLink(value: player) { PlayerRow(player: player) }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = player }
                        Button(player.active ? "Inactive" : "Active", systemImage: player.active ? "person.slash" : "person") {
                            player.active.toggle()
                        }
                    }
            }
            .onMove(perform: move)
        }
        .navigationTitle("Roster")
        .navigationDestination(for: Player.self) { PlayerEditor(player: $0) }
        .overlay {
            if team.players.isEmpty {
                // A GameChanger export brings the whole roster (and stats) in one step.
                ContentUnavailableView {
                    Label("No Players", systemImage: "person.3")
                } actions: {
                    Button("Import from GameChanger") { importing = true }
                        .buttonStyle(.borderedProminent)
                    Button("Add Player") { addPlayer() }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import from GameChanger", systemImage: "square.and.arrow.down") { importing = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Player", systemImage: "plus") { addPlayer() }
            }
        }
        .gameChangerImport(team: team, isPresented: $importing)
        .confirmationDialog("Delete \(deleting?.name ?? "this player")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Player", role: .destructive) {
                if let deleting { context.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("To keep their history, mark them inactive instead.")
        }
    }

    private func addPlayer() {
        let player = Player(name: "", sortIndex: (team.players.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(player)
        player.team = team
        path.append(player)
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
        HStack(spacing: 12) {
            Text(player.jersey.isEmpty ? "–" : player.jersey)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.name.isEmpty ? "New Player" : player.name)
                    .foregroundStyle(player.active && !player.name.isEmpty ? .primary : .secondary)
                if !player.active {
                    Text("Inactive").font(.caption).foregroundStyle(.secondary)
                } else if !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let profile = player.profile
        let best = profile.strengths.filter { profile[$0] >= .good }.prefix(3).map(\.label)
        return best.isEmpty ? "" : "Best at " + best.joined(separator: ", ")
    }
}

/// The coach's own read of a kid: number and name, where they play, what the numbers don't show, and ratings.
/// (Stats and the Scouting Report come with Insights, after 1.0.)
struct PlayerEditor: View {
    @Environment(\.modelContext) private var context
    @Bindable var player: Player
    @FocusState private var nameFocused: Bool
    @AppStorage("playerTab") private var tab: PlayerTab = .evaluation

    var body: some View {
        Group {
            switch tab {
            case .evaluation: evaluation
            case .stats, .scouting:
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if tab == .stats { stats } else { ScoutingReport(player: player) }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $tab) {
                ForEach(PlayerTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle(player.name.isEmpty ? "New Player" : player.name)
        .navigationBarTitleDisplayMode(.inline)
        // A player added and left without a name was a slip; one with anything else gets a placeholder name.
        .onDisappear {
            guard player.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if player.jersey.isEmpty && player.notes.isEmpty && player.ratings.isEmpty && player.profile == .default {
                context.delete(player)
            } else {
                player.name = "New Player"
            }
        }
    }

    @ViewBuilder
    private var stats: some View {
        if let stats = player.stats, let team = player.team {
            PlayerStatsPage(player: player, stats: stats, team: team)
        } else {
            Unlock(kind: .stats, title: "Season Stats", message: "Import your GameChanger season stats to see this player's numbers and where they rank on the team.", team: player.team)
        }
    }

    /// The coach's own read: number and name, where they play, what the numbers don't show, and ratings.
    private var evaluation: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    TextField("#", text: $player.jersey)
                        .keyboardType(.numberPad)
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(minWidth: 28, alignment: .leading)
                    TextField("Name", text: $player.name)
                        .font(.title2.weight(.bold))
                        .textContentType(.name)
                        .focused($nameFocused)
                }
                Toggle("Active", isOn: $player.active)
            }
            Section {
                FieldPositions(profile: Binding(get: { player.profile }, set: { player.profile = $0 }))
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            } header: {
                Text("Positions")
            } footer: {
                Text("Tap a position: doesn't play, plays, best.")
            }
            Section {
                TextField("What the stats don't show", text: $player.notes, axis: .vertical)
                    .lineLimit(3...10)
            } header: {
                Text("Notes")
            } footer: {
                Text("The AI reads these when it makes the lineup.")
            }
            RatingsSections(player: player)
        }
        .onAppear { if player.name.isEmpty { tab = .evaluation; nameFocused = true } }
    }
}

/// Positions on a to-scale Little League field. Tap to cycle: doesn't play → plays → best → doesn't play;
/// long-press to pick. (Stored as the position profile: Can't / Can / Primary.)
struct FieldPositions: View {
    @Binding var profile: PositionProfile

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                FieldDrawing()
                ForEach(Position.allCases, id: \.self) { position in
                    marker(position)
                        .position(FieldGeometry.point(FieldGeometry.fielder[position]!))
                }
            }
            .frame(width: FieldGeometry.size.width, height: FieldGeometry.size.height)

            HStack(spacing: 14) {
                legend(.cant, "Doesn't play")
                legend(.can, "Plays")
                legend(.primary, "Best")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .sensoryFeedback(.selection, trigger: profile)
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
            Dot(fit: fit, label: position.label, size: 44)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Doesn't Play") { profile[position] = .cant }
            Button("Plays") { profile[position] = .can }
            Button("Best") { profile[position] = .primary }
        }
        .accessibilityLabel("\(position.label): \(fit == .cant ? "doesn't play" : fit == .can ? "plays" : "best")")
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
                    Circle().fill(.background)
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                case .can:
                    Circle().fill(Color(white: 0.34))
                case .good, .primary:
                    Circle().fill(Color.accentColor)
                }
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 14, weight: fit >= .good ? .bold : .semibold))
                        .foregroundStyle(fit == .cant ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.white))
                }
                if fit >= .good && size > 20 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .offset(y: -size * 0.31)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
    }
}

/// Ratings grouped by kind, one section each; pitching and catching only show for players who do those.
struct RatingsSections: View {
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
        ForEach(groups, id: \.self) { group in
            Section(group.rawValue) {
                ForEach(RatingKey.allCases.filter { $0.group == group }, id: \.self) { key in
                    HStack {
                        Text(key.label)
                        Spacer()
                        StarRating(value: Binding(
                            get: { player.ratings[key] },
                            set: { var r = player.ratings; r[key] = $0; player.ratings = r }
                        ))
                    }
                }
            }
        }
    }
}

/// 1–5 stars; tap the current value again to clear it (unrated).
struct StarRating: View {
    @Binding var value: Int?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: "star.fill")
                    .foregroundStyle(star <= (value ?? 0) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
                    .onTapGesture { value = value == star ? nil : star }
            }
        }
        .sensoryFeedback(.selection, trigger: value)
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
