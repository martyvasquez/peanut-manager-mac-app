#if DEBUG
import Foundation

/// Debug-only launch flags, the iPhone's share of the Mac app's `DebugSupport` (same names, same meaning):
///   -PMStore Name        use a separate library file (keeps your real library untouched)
///   -PMSeedSample YES    create the sample team on launch if there are no teams
///   -PMFakeAI YES        use a scripted local "AI" instead of ChatGPT
///   -PMSignedOut YES     act signed out of ChatGPT (the real sign-in stays in the keychain)
///   -PMFakeClaudeKey YES act as if a Claude API key is saved (in memory only)
///   -PMNoAI YES          act as if no AI is set up
///   -PMAutoAllow YES     with -PMFakeAI: ask for consent, then press Allow a moment later
///   -PMModel id          use this model instead of the pinned one
///   -PMICloudWait YES    with an empty library, show the new-device wait for iCloud
enum DebugSupport {
    static var seedSample: Bool { UserDefaults.standard.bool(forKey: "PMSeedSample") }
    static var fakeAI: Bool { UserDefaults.standard.bool(forKey: "PMFakeAI") }
    static var signedOut: Bool { UserDefaults.standard.bool(forKey: "PMSignedOut") }
    static var fakeClaudeKey: Bool { UserDefaults.standard.bool(forKey: "PMFakeClaudeKey") }
    static var noAI: Bool { UserDefaults.standard.bool(forKey: "PMNoAI") }
    static var iCloudWait: Bool { UserDefaults.standard.bool(forKey: "PMICloudWait") }
    static var autoAllow: Bool { UserDefaults.standard.bool(forKey: "PMAutoAllow") }
    // Flags the shared sample builder reads; the iPhone doesn't auto-make lineups yet.
    static var autoGenerate: Bool { false }
    static var copyLastGame: Bool { false }
    nonisolated static var flakyScout: Bool { UserDefaults.standard.bool(forKey: "PMFlakyScout") }
    static var model: String? { UserDefaults.standard.string(forKey: "PMModel").flatMap { $0.isEmpty ? nil : $0 } }
}
#endif
