import SwiftUI
import SwiftData

@main
struct PeanutManagerApp: App {
    let container: ModelContainer

    init() {
        #if DEBUG
        if CloudKitCheck.requested { CloudKitCheck.run() }
        #endif
        container = Self.makeContainer()
        AppUpdater.shared.start()
        #if DEBUG
        if EvalRunner.requested { Task { [container] in await EvalRunner.run(container: container) } }
        #endif
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
        // iCloud sync stays off until the App Store build turns it on; the models are already CloudKit-safe.
        let configuration = ModelConfiguration(url: folder.appending(path: "\(name).store"), cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV1.self), configurations: configuration)
        } catch {
            fatalError("Couldn't open the Peanut Manager library: \(error)")
        }
    }
}
