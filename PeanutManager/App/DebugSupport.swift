#if DEBUG
import AppKit
import Foundation
import Synchronization
import SwiftData
import LineupKit

/// Debug-only launch flags for exercising the app without clicking or an API key:
///   -PMStore Name        use a separate library file (keeps your real library untouched)
///   -PMLibraryFolder Name use another Application Support folder instead of "Peanut Manager" (sandbox migration tests)
///   -PMSeedSample YES    create the sample team on launch if there are no teams, and open its game
///   -PMFakeAI YES        use a scripted local "AI" instead of ChatGPT
///   -PMAutoGenerate YES  make the batting order as soon as the first game opens (later games start empty)
///   -PMAutoPositions YES then set positions automatically
///   -PMOpenPicker YES    open the position picker on the third batter, inning 1
///   -PMScrollToChecks YES scroll to the game plan and checks once a lineup exists
///   -PMAssessTeam YES    assess the team as soon as Insights opens
///   -PMFlakyScout YES    fake Scout: Nguyen times out once, Brooks always times out
///   -PMSignedOut YES     act signed out of ChatGPT (the real sign-in stays in the keychain)
///   -PMShowSignIn YES    show the after-first-team Sign in with ChatGPT sheet
///   -PMFakeClaudeKey YES act as if a Claude API key is saved (in memory only; the keychain is untouched)
///   -PMNoAI YES          act as if no AI is set up: signed out of ChatGPT and no Claude key (the keychain is untouched)
///   -PMAddGame YES       add a game after the team's last one, with the sixth player out, and open it (to try Copy Last Game)
///   -PMCopyLastGame YES  copy the last game's lineup into an empty game when it opens
///   -PMHoverInning N     show inning N's header as if hovered (its menu button)
///   -PMDiamond N         open inning N on the field (the diamond popover)
///   -PMPlayerCard Name   open the player card for the first player whose name starts with Name
///   -PMBattingCard Name  open the batting card (Batting Order step) for the first player whose name starts with Name
///   -PMPrintTo path      once the lineup is filled, print it to a PDF at path (no print panel)
///   -PMRunEval YES       run the model eval on this (copied) library; see EvalRunner
///   -PMShowConsent openai|anthropic  show the share-with-AI-company sheet
///   -PMAutoAllow YES     with -PMFakeAI: ask for consent like a real provider, then press Allow a moment later
///   -PMAutoRemake YES    once the batting order exists, open Remake… and submit it ("Test remake")
///   -PMModel id          use this model instead of the pinned one (needs its service connected), e.g. claude-opus-5-5
///   -PMSync YES          sync this test library with iCloud (development environment); never the real library
///   -PMInitCloudKitSchema YES create the CloudKit schema in the development environment, then quit
///   -PMWindowSize WxH    size the main window in points (1440x900 = the 2880 × 1800 App Store screenshot)
///   -PMAppearance light|dark  force the appearance
///   -PMStep batting      open the game on the Batting Order step
///   -PMICloudWait YES    with an empty library, show the new-device wait for iCloud instead of the welcome screen
///   -PMCheckCloudKit YES check the schema against CloudKit's rules (and kids' data is encrypted), print, quit
enum DebugSupport {
    static var seedSample: Bool { UserDefaults.standard.bool(forKey: "PMSeedSample") }
    static var fakeAI: Bool { UserDefaults.standard.bool(forKey: "PMFakeAI") }
    static var autoGenerate: Bool { UserDefaults.standard.bool(forKey: "PMAutoGenerate") }
    static var autoPositions: Bool { UserDefaults.standard.bool(forKey: "PMAutoPositions") }
    static var scrollToChecks: Bool { UserDefaults.standard.bool(forKey: "PMScrollToChecks") }
    /// A section of the team page to scroll to: "offense", "defense", "practice".
    static var scrollTo: String? { UserDefaults.standard.string(forKey: "PMScrollTo") }
    static var assessTeam: Bool { UserDefaults.standard.bool(forKey: "PMAssessTeam") }
    static var signedOut: Bool { UserDefaults.standard.bool(forKey: "PMSignedOut") }
    static var showSignIn: Bool { UserDefaults.standard.bool(forKey: "PMShowSignIn") }
    static var fakeClaudeKey: Bool { UserDefaults.standard.bool(forKey: "PMFakeClaudeKey") }
    static var noAI: Bool { UserDefaults.standard.bool(forKey: "PMNoAI") }
    static var showAttendance: Bool { UserDefaults.standard.bool(forKey: "PMAttendance") }
    static var copyLastGame: Bool { UserDefaults.standard.bool(forKey: "PMCopyLastGame") }
    static var iCloudWait: Bool { UserDefaults.standard.bool(forKey: "PMICloudWait") }
    static var showConsent: String? { UserDefaults.standard.string(forKey: "PMShowConsent") }
    static var autoAllow: Bool { UserDefaults.standard.bool(forKey: "PMAutoAllow") }
    static var autoRemake: Bool { UserDefaults.standard.bool(forKey: "PMAutoRemake") }
    /// A model to try instead of the pinned one (testing a new model before it can ship).
    static var model: String? { UserDefaults.standard.string(forKey: "PMModel").flatMap { $0.isEmpty ? nil : $0 } }
    nonisolated static var flakyScout: Bool { UserDefaults.standard.bool(forKey: "PMFlakyScout") }

    /// The first game opened this run; the auto flags (generate, positions, copy) act on it alone.
    @MainActor private static var autoGame: PersistentIdentifier?

    @MainActor
    static func autoFills(_ game: Game) -> Bool {
        if autoGame == nil { autoGame = game.persistentModelID }
        return autoGame == game.persistentModelID
    }

    /// `-PMWindowSize 1440x900` sizes the main window (2880 × 1800 pixels on a Retina screen, the Mac App Store
    /// screenshot size); `-PMAppearance light|dark` forces the appearance.
    @MainActor
    static func prepareWindowForScreenshots() {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "PMAppearance") {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        guard let size = defaults.string(forKey: "PMWindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 else { return }
        Task {
            // The window may not exist yet, and may come back in full screen (remembered from earlier use).
            for _ in 0..<20 {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    if window.styleMask.contains(.fullScreen) {
                        window.toggleFullScreen(nil)
                        try? await Task.sleep(for: .seconds(1.5))
                    }
                    window.setFrame(NSRect(x: 40, y: 40, width: size[0], height: size[1]), display: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    @MainActor
    static func seedIfRequested(teams: [Team], context: ModelContext) -> Team? {
        guard seedSample, teams.isEmpty else { return nil }
        let team = try? SampleData.makeTeam(in: context)
        if UserDefaults.standard.bool(forKey: "PMNoStats"), let team {
            for player in team.players { player.stats = nil }
            team.statsImportedAt = nil
        }
        return team
    }

    /// A week after the team's last game; reuses the one made by an earlier run.
    @MainActor
    static func addGameIfRequested(to team: Team?, context: ModelContext) -> Game? {
        guard UserDefaults.standard.bool(forKey: "PMAddGame"), let team, let last = team.games.max(by: { $0.date < $1.date }) else { return nil }
        if last.opponent == "Next Opponent" { return last }
        let game = Game(opponent: "Next Opponent", date: Calendar.current.date(byAdding: .day, value: 7, to: last.date)!, innings: last.innings)
        context.insert(game)
        game.team = team
        game.ruleSet = last.ruleSet
        if let out = team.activePlayers.dropFirst(5).first { game.availability = [out.uid: .absent] }
        return game
    }
}
#endif
