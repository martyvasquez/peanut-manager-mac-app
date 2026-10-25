import SwiftUI
import SwiftData
import LineupKit

/// First launch: make a team, or explore with the bundled sample team. The Mac's words.
struct WelcomeView: View {
    var onCreate: (Team) -> Void
    @Binding var newTeam: Bool
    var loadSample: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "figure.baseball")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 8)
            Text("Peanut Manager").font(.largeTitle.weight(.bold))
            Text("Lineups in minutes.").font(.title3).foregroundStyle(.secondary)
            Spacer()
            Button { newTeam = true } label: {
                Text("New Team").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            Button { loadSample() } label: {
                Text("Try a Sample").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
        }
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}

/// Make or edit a team. A new team starts with the starter rules, as on the Mac.
struct TeamSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var team: Team?
    var onCreate: (Team) -> Void = { _ in }

    @State private var name = ""
    @State private var ageGroup = ""
    @State private var innings = 6
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Team Name", text: $name)
                    .focused($focused)
                TextField("Age Group", text: $ageGroup, prompt: Text("10U"))
                Picker("Innings", selection: $innings) {
                    ForEach([3, 4, 5, 6, 7, 9], id: \.self) { Text("\($0)").tag($0) }
                }
            }
            .navigationTitle(team == nil ? "New Team" : "Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(team == nil ? "Create" : "Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            if let team {
                name = team.name
                ageGroup = team.ageGroup
                innings = team.defaultInnings
            } else {
                focused = true
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

/// A new phone downloading the library from iCloud. It gives up after 30 seconds (`CloudSync`), then welcomes.
struct ICloudWaitView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.baseball")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 8)
            Text("Peanut Manager").font(.largeTitle.weight(.bold))
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking for your teams in iCloud…")
            }
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
