import AppKit
import CoreData
import Foundation
import Observation
import SwiftData

/// iCloud sync of the library (SwiftData + CloudKit), container `iCloud.com.martyvasquez.PeanutManager`.
/// Release builds (TestFlight, the App Store) sync the coach's library in CloudKit's production environment.
/// Debug builds talk to the development environment, so they never sync the real library: only a test library,
/// and only with `-PMSync YES`, so test data and the coach's data never share a zone.
@Observable
final class CloudSync {
    static let shared = CloudSync()

    /// The switch for sync as a whole (with the iCloud entitlement).
    nonisolated static let enabled = true
    nonisolated static let containerID = "iCloud.com.martyvasquez.PeanutManager"

    /// The library syncs this run.
    private(set) var isOn = false
    /// A new device is still downloading the library, so the first-launch screen waits instead of
    /// inviting a duplicate team.
    private(set) var isLookingInICloud = false

    private var observer: NSObjectProtocol?

    /// Whether a library syncs: the real one in release builds; in debug builds, only a test library with `-PMSync`.
    nonisolated static func syncs(isScratch: Bool) -> Bool {
        #if DEBUG
        return enabled && isScratch && UserDefaults.standard.bool(forKey: "PMSync")
        #else
        return enabled && !isScratch
        #endif
    }

    /// Call once the container exists. Waits for the first download from iCloud, at most `timeout` seconds.
    func start(syncing: Bool, timeout: Duration = .seconds(30)) {
        isOn = syncing
        // Changes made on another device arrive as silent pushes.
        if syncing { Task { NSApplication.shared.registerForRemoteNotifications() } }
        #if DEBUG
        if syncing { logEvents() }
        if DebugSupport.iCloudWait { isLookingInICloud = true; return }
        #endif
        // Signed out of iCloud: nothing will arrive, so don't wait.
        guard syncing, FileManager.default.ubiquityIdentityToken != nil else { return }
        isLookingInICloud = true
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { note in
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event
            guard let event, event.type == .import, event.endDate != nil else { return }
            MainActor.assumeIsolated { CloudSync.shared.doneLooking() }
        }
        Task {
            try? await Task.sleep(for: timeout)
            doneLooking()
        }
    }

    #if DEBUG
    /// Prints every sync event (setup, import, export) and its outcome, for sync tests.
    private func logEvents() {
        _ = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil else { return }
            let kind = event.type == .setup ? "setup" : event.type == .import ? "import" : "export"
            let line = "CloudSync: \(kind) \(event.succeeded ? "succeeded" : "failed: \(event.error.map { String(describing: $0) } ?? "?")")\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
    #endif

    private func doneLooking() {
        isLookingInICloud = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
