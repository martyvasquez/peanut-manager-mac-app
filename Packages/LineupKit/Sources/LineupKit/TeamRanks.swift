import Foundation

/// A season stat that players can be ranked on within their team.
public enum Metric: String, CaseIterable, Sendable {
    case avg, obp, slg, kRate, bbRate, sb, fpct, era, whip, pitchKRate

    public enum Kind: Sendable { case hitting, fielding, pitching }

    public var kind: Kind {
        switch self {
        case .avg, .obp, .slg, .kRate, .bbRate, .sb: .hitting
        case .fpct: .fielding
        case .era, .whip, .pitchKRate: .pitching
        }
    }

    /// Short label for tiles and columns: "OBP", "K%".
    public var label: String {
        switch self {
        case .avg: "AVG"
        case .obp: "OBP"
        case .slg: "SLG"
        case .kRate: "K%"
        case .bbRate: "BB%"
        case .sb: "SB"
        case .fpct: "FPCT"
        case .era: "ERA"
        case .whip: "WHIP"
        case .pitchKRate: "K%"
        }
    }

    /// What a leader in this stat is good at: "On Base", "Fewest Strikeouts".
    public var title: String {
        switch self {
        case .avg: "Batting Average"
        case .obp: "On Base"
        case .slg: "Power"
        case .kRate: "Fewest Strikeouts"
        case .bbRate: "Walks"
        case .sb: "Stolen Bases"
        case .fpct: "Fielding"
        case .era: "ERA"
        case .whip: "Fewest Baserunners"
        case .pitchKRate: "Strikeouts (Pitching)"
        }
    }

    /// Lower is better for strikeouts at the plate, ERA and WHIP.
    public var higherIsBetter: Bool {
        switch self {
        case .kRate, .era, .whip: false
        default: true
        }
    }

    public func value(_ stats: PlayerStats) -> Double? {
        switch self {
        case .avg: stats.batting?.avg
        case .obp: stats.batting?.obp
        case .slg: stats.batting?.slg
        case .kRate: stats.batting?.kRate
        case .bbRate: stats.batting?.bbRate
        case .sb: stats.batting.flatMap { $0.pa > 0 ? Double($0.sb) : nil }
        case .fpct: stats.fielding?.fpct
        case .era: stats.pitching?.era
        case .whip: stats.pitching?.whip
        case .pitchKRate: stats.pitching?.kPerBF
        }
    }

    /// The opportunities behind the number: plate appearances, chances or outs recorded.
    public func sample(_ stats: PlayerStats) -> Int {
        switch kind {
        case .hitting: stats.batting?.pa ?? 0
        case .fielding: stats.fielding?.tc ?? 0
        case .pitching: stats.pitching?.outs ?? 0
        }
    }

    /// The fewest opportunities that can ever qualify, however small the team's season is.
    var minimumSample: Int {
        switch kind {
        case .hitting: 10
        case .fielding: 5
        case .pitching: 9
        }
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .avg, .obp, .slg, .fpct: FactSheet.rate(value)
        case .kRate, .bbRate, .pitchKRate: FactSheet.percent(value)
        case .sb: String(Int(value))
        case .era, .whip: String(format: "%.2f", value)
        }
    }
}

/// Where one player stands on one stat. Players with too few opportunities get a value but no rank,
/// so a hot 6-at-bat start never reads as the team's best.
public struct Standing: Sendable, Hashable {
    public var player: PlayerID
    public var metric: Metric
    public var value: Double
    /// 1 is best; tied players share a rank. Nil when the sample is too small.
    public var rank: Int?
    public var tied: Bool
    /// How many players qualified.
    public var of: Int

    /// "1st", "T-3rd".
    public var rankText: String? {
        rank.map { (tied ? "T-" : "") + Self.ordinal($0) }
    }

    public static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }
}

/// Team rankings on every `Metric`, computed from season stats (never from the AI).
public struct TeamRanks: Sendable {
    /// Qualifying needs this share of the team's most opportunities (like MLB's per-game qualifier).
    public static let qualifyingShare = 0.4

    private var standings: [Metric: [Standing]] = [:]

    public init(_ players: [(id: PlayerID, stats: PlayerStats?)]) {
        for metric in Metric.allCases {
            let entries = players.compactMap { p -> (PlayerID, Double, Int)? in
                guard let stats = p.stats, let value = metric.value(stats) else { return nil }
                return (p.id, value, metric.sample(stats))
            }
            let most = entries.map(\.2).max() ?? 0
            let needed = max(metric.minimumSample, Int((Double(most) * Self.qualifyingShare).rounded(.up)))
            let qualified = entries.filter { $0.2 >= needed }
                .sorted { metric.higherIsBetter ? $0.1 > $1.1 : $0.1 < $1.1 }
            var list: [Standing] = []
            for entry in qualified {
                let rank = 1 + qualified.filter { metric.higherIsBetter ? $0.1 > entry.1 : $0.1 < entry.1 }.count
                let tied = qualified.filter { $0.1 == entry.1 }.count > 1
                list.append(Standing(player: entry.0, metric: metric, value: entry.1, rank: rank, tied: tied, of: qualified.count))
            }
            for entry in entries where entry.2 < needed {
                list.append(Standing(player: entry.0, metric: metric, value: entry.1, rank: nil, tied: false, of: qualified.count))
            }
            standings[metric] = list
        }
    }

    public func standing(_ player: PlayerID, _ metric: Metric) -> Standing? {
        standings[metric]?.first { $0.player == player }
    }

    /// Qualified players, best first.
    public func ranked(_ metric: Metric) -> [Standing] {
        (standings[metric] ?? []).filter { $0.rank != nil }
    }

    /// The top players, ties included, so a shared 3rd place shows every name.
    public func leaders(_ metric: Metric, top: Int = 3) -> [Standing] {
        ranked(metric).filter { $0.rank! <= top }
    }
}

/// The defense axis of the Two-Way Map: the coach's fielding ratings, nudged by the Scout's best position fit.
public enum TwoWay {
    public static let fieldingRatings: [RatingKey] = [.fieldingHands, .throwAccuracy, .armStrength, .flyBallAbility]

    /// Average fielding rating (1–5), +0.5 when the Scout's best fit anywhere is Strong, −0.5 when it's only
    /// Developing or worse. Nil without any fielding rating: the map leaves the player out rather than guess.
    public static func defense(ratings: Ratings, bestFit: PositionFit?) -> Double? {
        let rated = fieldingRatings.compactMap { ratings[$0] }
        guard !rated.isEmpty else { return nil }
        let average = Double(rated.reduce(0, +)) / Double(rated.count)
        let nudge: Double = switch bestFit {
        case .strong: 0.5
        case .developing, .notRecommended: -0.5
        case .solid, nil: 0
        }
        return min(max(average + nudge, 1), 5)
    }
}
