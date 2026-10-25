import SwiftUI
import SwiftData

@main
struct PeanutPhoneApp: App {
    let container: ModelContainer

    init() {
        container = Self.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(container)
    }

    /// The library's own folder (Application Support/Peanut Manager), as on the Mac.
    static var libraryFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Peanut Manager", directoryHint: .isDirectory)
    }

    /// The same library as the Mac app: the same schema and the same iCloud container, so a coach's teams,
    /// games and lineups appear on both. Test libraries (`-PMStore Name`) never sync.
    static func makeContainer() -> ModelContainer {
        let folder = libraryFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = "Library"
        #if DEBUG
        if let scratch = UserDefaults.standard.string(forKey: "PMStore"), !scratch.isEmpty { name = scratch }
        #endif
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
