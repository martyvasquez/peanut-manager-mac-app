import Foundation
import Observation

/// App-wide navigation, so a screen can send the coach somewhere else (e.g. "Open Roster").
@Observable
final class Navigator {
    static let shared = Navigator()
    var section: SidebarSection? = .games
    /// A player to select in Roster; ContentView picks it up and clears it.
    var playerToOpen: Player?

    func openScoutingReport(_ player: Player) {
        open(player, tab: .scouting)
    }

    func open(_ player: Player, tab: PlayerTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "playerTab")
        playerToOpen = player
        section = .roster
    }
}
