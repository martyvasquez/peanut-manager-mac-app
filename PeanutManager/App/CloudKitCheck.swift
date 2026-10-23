#if DEBUG
import CoreData
import Foundation
import SwiftData

/// `-PMCheckCloudKit YES`: checks the library schema against CloudKit's rules, prints what it finds and quits.
/// Every attribute needs a default or must be optional, every relationship must be optional with an inverse,
/// nothing may be unique, and anything about a kid must be encrypted. Also reports where a synced keychain item lands.
enum CloudKitCheck {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "PMCheckCloudKit") }
    static var initSchemaRequested: Bool { UserDefaults.standard.bool(forKey: "PMInitCloudKitSchema") }

    /// `-PMInitCloudKitSchema YES`: creates every record type and field (encrypted ones included) in the container's
    /// development environment, ready to deploy to production in the CloudKit Console. Prints the outcome and quits.
    /// Apple's way for SwiftData: the same model, loaded once into a Core Data CloudKit container.
    static func initializeSchema() -> Never {
        let folder = PeanutManagerApp.libraryFolder
        let url = folder.appending(path: "CloudKitSchema.store")
        var failure: String?
        autoreleasepool {
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: LibrarySchemaV1.models) else {
                failure = "couldn't build the model"; return
            }
            let description = NSPersistentStoreDescription(url: url)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: CloudSync.containerID)
            description.shouldAddStoreAsynchronously = false
            let container = NSPersistentCloudKitContainer(name: "CloudKitSchema", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            container.loadPersistentStores { _, error in if let error { failure = "load: \(error)" } }
            guard failure == nil else { return }
            do {
                try container.initializeCloudKitSchema()
            } catch {
                failure = "initialize: \(error)"
            }
            if let store = container.persistentStoreCoordinator.persistentStores.first {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }
        for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: folder.appending(path: "CloudKitSchema.store" + suffix)) }
        try? FileManager.default.removeItem(at: folder.appending(path: "CloudKitSchema_ckAssets"))
        print(failure.map { "CloudKitSchema: failed, \($0)" } ?? "CloudKitSchema: OK, development schema created for \(CloudSync.containerID)")
        exit(failure == nil ? 0 : 1)
    }

    static func run() -> Never {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: LibrarySchemaV1.models) else {
            print("CloudKitCheck: couldn't build the model"); exit(1)
        }
        var problems: [String] = []
        for entity in model.entities.sorted(by: { $0.name! < $1.name! }) {
            let name = entity.name!
            if !entity.uniquenessConstraints.isEmpty { problems.append("\(name): unique constraint") }
            for attribute in entity.attributesByName.values.sorted(by: { $0.name < $1.name }) {
                if !attribute.isOptional && attribute.defaultValue == nil {
                    problems.append("\(name).\(attribute.name): no default and not optional")
                }
                print("  \(name).\(attribute.name)\(attribute.allowsCloudEncryption ? "  [encrypted]" : "")")
            }
            for relationship in entity.relationshipsByName.values.sorted(by: { $0.name < $1.name }) {
                if !relationship.isOptional { problems.append("\(name).\(relationship.name): relationship not optional") }
                if relationship.inverseRelationship == nil { problems.append("\(name).\(relationship.name): no inverse") }
                print("  \(name).\(relationship.name) → \(relationship.destinationEntity?.name ?? "?")")
            }
        }
        // Where a synced secret lands: iCloud Keychain needs the iCloud entitlement; otherwise this Mac's keychain.
        let probe = "cloudkit-check-probe"
        Keychain.set(Data("probe".utf8), for: probe, synced: true)
        let stored = Keychain.data(probe) != nil
        print("Keychain: \(!stored ? "couldn't save" : Keychain.isSynced(probe) ? "synced item is in iCloud Keychain" : "synced item fell back to this Mac's keychain")")
        Keychain.set(nil, for: probe)
        if !stored || Keychain.data(probe) != nil { problems.append("Keychain: probe item didn't save or didn't delete") }
        print("Sync: \(CloudSync.enabled ? "enabled" : "off") · container \(CloudSync.containerID)")
        print(problems.isEmpty ? "CloudKitCheck: OK" : "CloudKitCheck: \(problems.count) problem(s)\n" + problems.joined(separator: "\n"))
        exit(problems.isEmpty ? 0 : 1)
    }
}
#endif
