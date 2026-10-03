import Foundation

/// One number or statement code knows to be true, with a stable ID the AI cites instead of
/// writing the value itself. The UI renders `label` and `value` next to each claim.
public struct Fact: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var value: String

    public init(_ id: String, _ label: String, _ value: String) {
        self.id = id
        self.label = label
        self.value = value
    }

    public var display: String { "\(label) \(value)" }
}

/// Everything the Scout may cite about one player (or the team), computed in code.
public struct FactSheet: Codable, Sendable, Hashable {
    public var facts: [Fact]

    public init(_ facts: [Fact] = []) {
        self.facts = facts
    }

    public subscript(id: String) -> Fact? { facts.first { $0.id == id } }
    public func contains(_ id: String) -> Bool { self[id] != nil }
    public var isEmpty: Bool { facts.isEmpty }

    /// "[obp] OBP .412" per line, as the prompt shows it.
    public var promptText: String {
        facts.isEmpty ? "(no facts)" : facts.map { "[\($0.id)] \($0.label): \($0.value)" }.joined(separator: "\n")
    }

    /// A stable fingerprint of the inputs. An assessment is stale when this changes.
    public var fingerprint: String {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a: stable across launches, unlike Hasher.
        for byte in facts.map({ "\($0.id)=\($0.value)" }).joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

extension FactSheet {
    /// Stats, ratings, positions and notes for one player. Unknowns are left out, never defaulted.
    public static func player(_ player: PlayerSnapshot) -> FactSheet {
        var facts: [Fact] = []

        if let b = player.stats?.batting, b.pa > 0 {
            facts += [
                Fact("pa", "Plate appearances", "\(b.pa)"),
                Fact("avg", "AVG", rate(b.avg)),
                Fact("obp", "OBP", rate(b.obp)),
                Fact("slg", "SLG", rate(b.slg)),
                Fact("k_rate", "K%", percent(b.kRate)),
                Fact("bb_rate", "BB%", percent(b.bbRate)),
                Fact("xbh", "Extra-base hits", "\(b.doubles + b.triples + b.hr)"),
                Fact("rbi", "RBI", "\(b.rbi)"),
                Fact("sb", "Stolen bases", "\(b.sb) of \(b.sb + b.cs)"),
            ]
        }

        if let f = player.stats?.fielding {
            if f.tc > 0 {
                facts += [
                    Fact("tc", "Total chances", "\(f.tc)"),
                    Fact("fpct", "Fielding %", rate(f.fpct)),
                    Fact("errors", "Errors", "\(f.e)"),
                ]
            }
            for (position, innings) in f.innings.sorted(by: { $0.key < $1.key }) where innings > 0 {
                facts.append(Fact("inn.\(position.rawValue.lowercased())", "Innings at \(position.label)", decimal(innings)))
            }
            if f.catcherOuts > 0 {
                facts += [
                    Fact("c.innings", "Innings caught", decimal(f.catcherInnings)),
                    Fact("c.pb", "Passed balls", "\(f.passedBalls)"),
                    Fact("c.cs", "Runners caught stealing", "\(f.caughtStealing) of \(f.caughtStealing + f.stolenBasesAllowed)"),
                ]
            }
        }

        if let p = player.stats?.pitching, p.outs > 0 {
            facts += [
                Fact("p.ip", "Innings pitched", p.ipText),
                Fact("p.era", "ERA", p.era.map { String(format: "%.2f", $0) } ?? "–"),
                Fact("p.whip", "WHIP", p.whip.map { String(format: "%.2f", $0) } ?? "–"),
                Fact("p.k_rate", "Pitching K%", percent(p.kPerBF)),
                Fact("p.bb_rate", "Pitching BB%", percent(p.bf > 0 ? Double(p.bb) / Double(p.bf) : nil)),
            ]
        }

        for key in RatingKey.allCases {
            if let stars = player.ratings[key] {
                facts.append(Fact("rating.\(key.rawValue)", key.label, "\(stars)/5"))
            }
        }

        for position in Position.allCases {
            let fit = player.profile[position]
            let text = switch fit {
            case .cant: "doesn't play"
            case .can: "plays"
            case .good: "good"
            case .primary: "best"
            }
            facts.append(Fact("pos.\(position.rawValue.lowercased())", position.label, text))
        }

        for (index, line) in noteLines(player.notes).enumerated() {
            facts.append(Fact("note.\(index + 1)", "Coach note", line))
        }

        return FactSheet(facts)
    }

    /// Team totals, computed from counts (never averages of averages).
    public static func team(_ players: [PlayerSnapshot]) -> FactSheet {
        let batting = players.compactMap { $0.stats?.batting }
        let fielding = players.compactMap { $0.stats?.fielding }
        let pitching = players.compactMap { $0.stats?.pitching }
        var total = BattingLine()
        for b in batting {
            total.pa += b.pa; total.ab += b.ab; total.h += b.h
            total.singles += b.singles; total.doubles += b.doubles; total.triples += b.triples; total.hr += b.hr
            total.bb += b.bb; total.so += b.so; total.hbp += b.hbp; total.sb += b.sb; total.cs += b.cs
        }
        var facts = [Fact("team.players", "Players", "\(players.count)")]
        if total.pa > 0 {
            facts += [
                Fact("team.pa", "Team plate appearances", "\(total.pa)"),
                Fact("team.avg", "Team AVG", rate(total.avg)),
                Fact("team.obp", "Team OBP", rate(total.obp)),
                Fact("team.slg", "Team SLG", rate(total.slg)),
                Fact("team.k_rate", "Team K%", percent(total.kRate)),
                Fact("team.bb_rate", "Team BB%", percent(total.bbRate)),
                Fact("team.sb", "Team stolen bases", "\(total.sb) of \(total.sb + total.cs)"),
            ]
        }
        let tc = fielding.reduce(0) { $0 + $1.tc }
        if tc > 0 {
            let outs = fielding.reduce(0) { $0 + $1.po + $1.a }
            facts += [
                Fact("team.fpct", "Team fielding %", rate(Double(outs) / Double(tc))),
                Fact("team.errors", "Team errors", "\(fielding.reduce(0) { $0 + $1.e })"),
            ]
        }
        let outs = pitching.reduce(0) { $0 + $1.outs }
        if outs > 0 {
            let innings = Double(outs) / 3
            let walksHits = pitching.reduce(0) { $0 + $1.bb + $1.h }
            facts += [
                Fact("team.p.ip", "Team innings pitched", "\(outs / 3).\(outs % 3)"),
                Fact("team.p.whip", "Team WHIP", String(format: "%.2f", Double(walksHits) / innings)),
            ]
        }
        facts.append(Fact("team.pitchers", "Players who can pitch", "\(players.filter { $0.profile.canPlay(.p) }.count)"))
        facts.append(Fact("team.catchers", "Players who can catch", "\(players.filter { $0.profile.canPlay(.c) }.count)"))
        return FactSheet(facts)
    }

    static func noteLines(_ notes: String) -> [String] {
        notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "–" }
        let s = String(format: "%.3f", value)
        return s.hasPrefix("0.") ? String(s.dropFirst()) : s
    }

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "–"
    }

    static func decimal(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
