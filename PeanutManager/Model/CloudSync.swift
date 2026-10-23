import CoreData
import Foundation
import Observation
import SwiftData

/// iCloud sync of the library (SwiftData + CloudKit). Off until the App Store build adds the iCloud capability;
/// turning it on is `enabled = true` plus the entitlement. Test libraries (`-PMStore`) never sync.
@Observable
final class CloudSync {
    static let shared = CloudSync()

    /// Flip together with the iCloud (CloudKit) entitlement and the production schema deploy.
    nonisolated static let enabled = false
    nonisolated static let containerID = "iCloud.com.martyvasquez.PeanutManager"

    /// The library syncs this run.
    private(set) var isOn = false
    /// A new device is still downloading the library, so the first-launch screen waits instead of
    /// inviting a duplicate team.
    private(set) var isLookingInICloud = false

    private var observer: NSObjectProtocol?

    /// Whether a library syncs: only the real one, and only once sync is enabled.
    nonisolated static func syncs(isScratch: Bool) -> Bool { enabled && !isScratch }

    /// Call once the container exists. Waits for the first download from iCloud, at most `timeout` seconds.
    func start(syncing: Bool, timeout: Duration = .seconds(30)) {
        isOn = syncing
        #if DEBUG
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

    private func doneLooking() {
        isLookingInICloud = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
