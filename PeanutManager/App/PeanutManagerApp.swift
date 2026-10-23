import SwiftUI
import SwiftData

@main
struct PeanutManagerApp: App {
    let container: ModelContainer

    init() {
        #if DEBUG
        if CloudKitCheck.requested { CloudKitCheck.run() }
        if CloudKitCheck.initSchemaRequested { CloudKitCheck.initializeSchema() }
        #endif
        container = Self.makeContainer()
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
        }

        Settings {
            SettingsView()
        }
    }

    /// The library's own folder (Application Support/Peanut Manager, inside the sandbox container), never the
    /// shared default store. `-PMLibraryFolder Name` uses another folder (to test the sandbox migration).
    static var libraryFolder: URL {
        var name = "Peanut Manager"
        #if DEBUG
        if let other = UserDefaults.standard.string(forKey: "PMLibraryFolder"), !other.isEmpty { name = other }
        #endif
        return URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    static func makeContainer() -> ModelContainer {
        let folder = libraryFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = "Library"
        #if DEBUG
        if let scratch = UserDefaults.standard.string(forKey: "PMStore"), !scratch.isEmpty { name = scratch }
        #endif
        // Only the real library ever syncs; test libraries stay on this Mac so they never reach the coach's iCloud.
        let syncing = CloudSync.syncs(isScratch: name != "Library")
        let configuration = ModelConfiguration(
            url: folder.appending(path: "\(name).store"),
            cloudKitDatabase: syncing ? .private(CloudSync.containerID) : .none
        )
        do {
            let container = try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV1.self), configurations: configuration)
            CloudSync.shared.start(syncing: syncing)
            return container
        } catch {
            fatalError("Couldn't open the Peanut Manager library: \(error)")
        }
    }
}
