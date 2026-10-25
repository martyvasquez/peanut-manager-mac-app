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
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
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

/// A new device downloading the library from iCloud: wait here rather than offer New Team and make a duplicate.
struct ICloudWaitView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("Peanut Manager").font(.largeTitle.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for your teams in iCloud…")
            }
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
