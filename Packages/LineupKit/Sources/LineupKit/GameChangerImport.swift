import Foundation

/// One player row from a GameChanger season stats export.
public struct GameChangerRow: Sendable, Hashable {
    public var number: String
    public var first: String
    public var last: String
    public var batting: BattingLine
    public var fielding: FieldingLine
    public var pitching: PitchingLine

    public var fullName: String { [first, last].filter { !$0.isEmpty }.joined(separator: " ") }
}

public enum GameChangerImportError: Error, LocalizedError, Equatable {
    case notGameChangerExport
    case missingSection(String)
    case noPlayers

    public var errorDescription: String? {
        switch self {
        case .notGameChangerExport: "This doesn't look like a GameChanger stats export (no Number / Last / First header)."
        case .missingSection(let name): "The export has no \(name) section. Export season stats from GameChanger with all stat groups."
        case .noPlayers: "The export has no player rows."
        }
    }
}

/// Parses GameChanger "season stats" CSV exports.
///
/// The export's first row names the stat sections ("Batting", "Pitching", "Fielding") at the column where each
/// begins; column names repeat across sections (H, BB, SO, SB…), so columns are looked up *within* their section.
/// v1 guessed sections from hard-coded column indexes; a format change there would silently shift stats.
public enum GameChangerImport {
    public static func parse(_ text: String) throws -> [GameChangerRow] {
        let rows = CSV.parse(text)
        guard let headerIndex = rows.prefix(6).firstIndex(where: { row in
            let cells = row.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return cells.starts(with: ["number", "last", "first"])
        }) else { throw GameChangerImportError.notGameChangerExport }

        let header = rows[headerIndex].map { $0.trimmingCharacters(in: .whitespaces) }
        let sections = sectionRanges(sectionRow: headerIndex > 0 ? rows[headerIndex - 1] : [], width: header.count)
        guard let battingRange = sections["batting"] else { throw GameChangerImportError.missingSection("Batting") }

        func columns(_ range: Range<Int>?) -> [String: Int] {
            guard let range else { return [:] }
            var map: [String: Int] = [:]
            for index in range where index < header.count && map[header[index]] == nil {
                map[header[index]] = index
            }
            return map
        }
        let bat = columns(battingRange)
        let pit = columns(sections["pitching"])
        let fld = columns(sections["fielding"])

        var players: [GameChangerRow] = []
        for row in rows.dropFirst(headerIndex + 1) {
            let first = row.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if first.lowercased() == "glossary" { break }
            if first.isEmpty || first.lowercased() == "totals" { continue }

            func int(_ map: [String: Int], _ key: String) -> Int {
                guard let i = map[key], i < row.count else { return 0 }
                return Int(row[i].trimmingCharacters(in: .whitespaces)) ?? 0
            }
            func double(_ map: [String: Int], _ key: String) -> Double? {
                guard let i = map[key], i < row.count else { return nil }
                return Double(row[i].trimmingCharacters(in: .whitespaces))
            }

            var b = BattingLine()
            b.gp = int(bat, "GP"); b.pa = int(bat, "PA"); b.ab = int(bat, "AB"); b.h = int(bat, "H")
            b.singles = int(bat, "1B"); b.doubles = int(bat, "2B"); b.triples = int(bat, "3B"); b.hr = int(bat, "HR")
            b.rbi = int(bat, "RBI"); b.r = int(bat, "R"); b.bb = int(bat, "BB"); b.so = int(bat, "SO")
            b.hbp = int(bat, "HBP"); b.sb = int(bat, "SB"); b.cs = int(bat, "CS")

            var f = FieldingLine()
            f.tc = int(fld, "TC"); f.po = int(fld, "PO"); f.a = int(fld, "A"); f.e = int(fld, "E"); f.dp = int(fld, "DP")
            for position in Position.allCases {
                if let innings = double(fld, position.rawValue), innings > 0 { f.innings[position] = innings }
            }

            var p = PitchingLine()
            if let i = pit["IP"], i < row.count { p.outs = PitchingLine.outs(fromIP: row[i].trimmingCharacters(in: .whitespaces)) ?? 0 }
            p.gp = int(pit, "GP"); p.gs = int(pit, "GS"); p.bf = int(pit, "BF"); p.pitches = int(pit, "#P")
            p.h = int(pit, "H"); p.r = int(pit, "R"); p.er = int(pit, "ER"); p.bb = int(pit, "BB"); p.so = int(pit, "SO"); p.hbp = int(pit, "HBP")

            players.append(GameChangerRow(
                number: first,
                first: row.count > 2 ? row[2].trimmingCharacters(in: .whitespaces) : "",
                last: row.count > 1 ? row[1].trimmingCharacters(in: .whitespaces) : "",
                batting: b, fielding: f, pitching: p
            ))
        }
        guard !players.isEmpty else { throw GameChangerImportError.noPlayers }
        return players
    }

    /// Maps section names to column ranges using the row above the header.
    static func sectionRanges(sectionRow: [String], width: Int) -> [String: Range<Int>] {
        let starts = sectionRow.enumerated().compactMap { index, cell -> (String, Int)? in
            let name = cell.trimmingCharacters(in: .whitespaces).lowercased()
            return name.isEmpty ? nil : (name, index)
        }
        guard !starts.isEmpty else {
            // No section row: treat everything after the name columns as batting (the first section).
            return ["batting": 3..<width]
        }
        var ranges: [String: Range<Int>] = [:]
        for (i, (name, start)) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].1 : width
            ranges[name] = start..<end
        }
        return ranges
    }

    // MARK: - Matching

    public enum Match: Sendable, Hashable {
        case jersey(PlayerID)
        case name(PlayerID)
        case none
        /// More than one roster player could be this row; the coach must choose.
        case ambiguous([PlayerID])

        public var player: PlayerID? {
            switch self {
            case .jersey(let id), .name(let id): id
            case .none, .ambiguous: nil
            }
        }
    }

    /// Exact matching only: jersey number, then full name. No "last name contains" guesses (v1 blind spot #19).
    public static func match(_ row: GameChangerRow, roster: [PlayerSnapshot]) -> Match {
        let byJersey = roster.filter { ($0.jersey ?? "").trimmingCharacters(in: .whitespaces) == row.number && !row.number.isEmpty }
        if byJersey.count == 1 { return .jersey(byJersey[0].id) }

        let target = normalize(row.fullName)
        let byName = roster.filter { normalize($0.name) == target || normalize(reversed($0.name)) == target }
        if byName.count == 1 { return .name(byName[0].id) }
        if byJersey.count > 1 || byName.count > 1 { return .ambiguous((byJersey + byName).map(\.id)) }
        return .none
    }

    static func normalize(_ name: String) -> String {
        name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Last, First" → "First Last".
    static func reversed(_ name: String) -> String {
        let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? "\(parts[1]) \(parts[0])" : name
    }
}

/// Minimal RFC 4180 CSV reader (quoted fields, escaped quotes, CRLF, BOM).
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let c = next() {
            if c == "\u{FEFF}" { continue }
            if inQuotes {
                if c == "\"" {
                    if let following = next() {
                        if following == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = following }
                    } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r": continue
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
