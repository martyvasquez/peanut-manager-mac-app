import Observation

/// App-wide navigation, so a screen can send the coach somewhere else (e.g. "Open Roster").
@Observable
final class Navigator {
    static let shared = Navigator()
    var section: SidebarSection? = .games
}
