#if DEBUG
import CoreData
import Foundation
import SwiftData

/// `-PMCheckCloudKit YES`: checks the library schema against CloudKit's rules, prints what it finds and quits.
/// Every attribute needs a default or must be optional, every relationship must be optional with an inverse,
/// nothing may be unique, and anything about a kid must be encrypted. Also reports where a synced keychain item lands.
enum CloudKitCheck {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "PMCheckCloudKit") }

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
