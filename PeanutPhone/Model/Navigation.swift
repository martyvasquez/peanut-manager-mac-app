import Foundation

/// The phone's tabs, under the name the Mac's `Navigator` uses for its sidebar, so the shared Insights views can
/// send the coach to the Roster or a kid's Scouting Report.
enum SidebarSection: Hashable {
    case games, roster, rules, insights
}

/// A player's page: their season, the AI's Scouting Report, and the coach's own evaluation. The Mac's tabs.
enum PlayerTab: String, CaseIterable {
    case stats, scouting, evaluation

    var title: String {
        switch self {
        case .stats: "Stats"
        case .scouting: "Scouting"
        case .evaluation: "Evaluation"
        }
    }
}
