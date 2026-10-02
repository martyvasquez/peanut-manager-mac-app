import Foundation

/// Season-to-date batting counts. Rates are always computed here, never trusted from the CSV.
public struct BattingLine: Codable, Sendable, Hashable {
    public var gp = 0, pa = 0, ab = 0, h = 0
    public var singles = 0, doubles = 0, triples = 0, hr = 0
    public var rbi = 0, r = 0, bb = 0, so = 0, hbp = 0, sb = 0, cs = 0

    public init() {}

    public var avg: Double? { ab > 0 ? Double(h) / Double(ab) : nil }
    public var obp: Double? { pa > 0 ? Double(h + bb + hbp) / Double(pa) : nil }
    public var slg: Double? {
        ab > 0 ? Double(singles + 2 * doubles + 3 * triples + 4 * hr) / Double(ab) : nil
    }
    public var kRate: Double? { pa > 0 ? Double(so) / Double(pa) : nil }
    public var bbRate: Double? { pa > 0 ? Double(bb) / Double(pa) : nil }
    public var sbPct: Double? { sb + cs > 0 ? Double(sb) / Double(sb + cs) : nil }
}

public struct FieldingLine: Codable, Sendable, Hashable {
    public var tc = 0, po = 0, a = 0, e = 0, dp = 0
    /// Innings played at each position (GameChanger's per-position fielding columns; often all zero).
    public var innings: [Position: Double] = [:]
    /// Outs caught behind the plate (GameChanger's catching "INN" column), plus catching results.
    public var catcherOuts = 0
    public var passedBalls = 0
    public var stolenBasesAllowed = 0
    public var caughtStealing = 0

    public init() {}

    public var catcherInnings: Double { Double(catcherOuts) / 3 }

    enum CodingKeys: String, CodingKey { case tc, po, a, e, dp, innings, catcherOuts, passedBalls, stolenBasesAllowed, caughtStealing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tc = try c.decodeIfPresent(Int.self, forKey: .tc) ?? 0
        po = try c.decodeIfPresent(Int.self, forKey: .po) ?? 0
        a = try c.decodeIfPresent(Int.self, forKey: .a) ?? 0
        e = try c.decodeIfPresent(Int.self, forKey: .e) ?? 0
        dp = try c.decodeIfPresent(Int.self, forKey: .dp) ?? 0
        innings = try c.decodeIfPresent([Position: Double].self, forKey: .innings) ?? [:]
        catcherOuts = try c.decodeIfPresent(Int.self, forKey: .catcherOuts) ?? 0
        passedBalls = try c.decodeIfPresent(Int.self, forKey: .passedBalls) ?? 0
        stolenBasesAllowed = try c.decodeIfPresent(Int.self, forKey: .stolenBasesAllowed) ?? 0
        caughtStealing = try c.decodeIfPresent(Int.self, forKey: .caughtStealing) ?? 0
    }

    public var fpct: Double? { tc > 0 ? Double(po + a) / Double(tc) : nil }
}

public struct PitchingLine: Codable, Sendable, Hashable {
    /// Outs recorded. GameChanger writes IP as "12.1" meaning 12⅓ innings.
    public var outs = 0
    public var gp = 0, gs = 0, bf = 0, pitches = 0
    public var h = 0, r = 0, er = 0, bb = 0, so = 0, hbp = 0

    public init() {}

    public var innings: Double { Double(outs) / 3 }
    /// Baseball notation: 10 outs → "3.1" (3⅓ innings).
    public var ipText: String { "\(outs / 3).\(outs % 3)" }
    public var era: Double? { outs > 0 ? Double(er) * 9 / innings : nil }
    public var whip: Double? { outs > 0 ? Double(bb + h) / innings : nil }
    public var kPerBF: Double? { bf > 0 ? Double(so) / Double(bf) : nil }

    /// "12.1" → 37 outs.
    public static func outs(fromIP text: String) -> Int? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int(parts.first ?? "") else { return nil }
        let thirds = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        guard (0...2).contains(thirds) else { return nil }
        return whole * 3 + thirds
    }
}

public struct PlayerStats: Codable, Sendable, Hashable {
    public var batting: BattingLine?
    public var fielding: FieldingLine?
    public var pitching: PitchingLine?
    public var importedAt: Date

    public init(batting: BattingLine? = nil, fielding: FieldingLine? = nil, pitching: PitchingLine? = nil, importedAt: Date = .now) {
        self.batting = batting
        self.fielding = fielding
        self.pitching = pitching
        self.importedAt = importedAt
    }
}
