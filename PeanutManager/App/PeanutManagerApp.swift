import SwiftUI
import SwiftData

@main
struct PeanutManagerApp: App {
    let container: ModelContainer

    init() {
        container = Self.makeContainer()
        AppUpdater.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 920)
        .modelContainer(container)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                    .disabled(!AppUpdater.shared.canCheck)
            }
        }

        Settings {
            SettingsView()
        }
    }

    /// The library lives in its own folder (~/Library/Application Support/Peanut Manager), never the shared default store.
    static func makeContainer() -> ModelContainer {
        let folder = URL.applicationSupportDirectory.appending(path: "Peanut Manager", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = "Library"
        #if DEBUG
        if let scratch = UserDefaults.standard.string(forKey: "PMStore"), !scratch.isEmpty { name = scratch }
        #endif
        let configuration = ModelConfiguration(url: folder.appending(path: "\(name).store"))
        do {
            return try ModelContainer(for: Team.self, Player.self, RuleSet.self, Rule.self, Game.self, configurations: configuration)
        } catch {
            fatalError("Couldn't open the Peanut Manager library: \(error)")
        }
    }
}
