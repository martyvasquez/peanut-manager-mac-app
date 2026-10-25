import SwiftUI
import SwiftData
import LineupKit

/// Every season number from the GameChanger import, on a phone: names pinned on the left, the columns scroll
/// sideways (like a long game's innings). Batting, fielding, pitching or catching; tap a column to sort by it.
/// The Mac's `StatsView` is one wide table; this is its narrow form, with the same import.
struct StatsView: View {
    let team: Team
    @AppStorage("phoneStatsGroup") private var group: StatGroup = .batting
    @State private var sort: String?
    @State private var descending = true
    @State private var importing = false

    private let rowHeight: CGFloat = 40
    private let nameWidth: CGFloat = 116
    private let columnWidth: CGFloat = 54

    var body: some View {
        let columns = group.columns
        let key = sort.flatMap { id in columns.first { $0.id == id } } ?? columns.first { $0.isDefaultSort } ?? columns[0]
        let players = team.activePlayers.filter { $0.stats.map(group.has) ?? false }
        let rows = players.sorted { a, b in
            switch (key.value(a.stats!), key.value(b.stats!)) {
            case let (x?, y?): return x == y ? a.sortIndex < b.sortIndex : (descending ? x > y : x < y)
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.sortIndex < b.sortIndex
            }
        }
        VStack(spacing: 0) {
            Picker("Group", selection: $group) {
                ForEach(StatGroup.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .onChange(of: group) { sort = nil; descending = true }

            if team.activePlayers.allSatisfy({ $0.stats == nil }) {
                Unlock(kind: .stats, title: "Season Stats", message: "Import your GameChanger season stats to see every kid's numbers and where they rank.", team: team)
                    .padding(16)
                Spacer()
            } else if rows.isEmpty {
                ContentUnavailableView("No \(group.title) Stats", systemImage: "chart.bar.xaxis")
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        // Names stay put.
                        VStack(spacing: 0) {
                            Text("Player").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                            ForEach(rows) { player in
                                HStack(spacing: 6) {
                                    Text(player.jersey).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                        .frame(width: 22, alignment: .trailing)
                                    Text(Self.short(player.name)).font(.subheadline).lineLimit(1)
                                }
                                .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                                .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                        ScrollView(.horizontal) {
                            VStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    ForEach(columns) { column in header(column, sorted: column.id == key.id) }
                                }
                                ForEach(rows) { player in
                                    HStack(spacing: 0) {
                                        ForEach(columns) { column in
                                            Text(column.text(player.stats!))
                                                .font(.subheadline.monospacedDigit().weight(column.id == key.id ? .semibold : .regular))
                                                .foregroundStyle(column.value(player.stats!) == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                                .frame(width: columnWidth, height: rowHeight, alignment: .trailing)
                                        }
                                    }
                                    .overlay(alignment: .bottom) { Divider() }
                                }
                            }
                            .padding(.trailing, 16)
                        }
                        .scrollIndicators(.hidden)
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import", systemImage: "square.and.arrow.down") { importing = true }
            }
        }
        .gameChangerImport(team: team, isPresented: $importing)
    }

    private func header(_ column: StatColumn, sorted: Bool) -> some View {
        Button {
            if sorted { descending.toggle() } else { sort = column.id; descending = column.higherIsBetter }
        } label: {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                if sorted { Image(systemName: descending ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold)) }
                Text(column.id)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(sorted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: columnWidth, height: rowHeight, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(column.id)")
    }

    /// "Gray M."
    private static func short(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard let first = parts.first, parts.count > 1, let initial = parts.last?.first else { return name }
        return "\(first) \(initial)."
    }
}

enum StatGroup: String, CaseIterable {
    case batting, fielding, pitching, catching

    var title: String { rawValue.capitalized }

    /// Kids with something to show in this group.
    func has(_ s: PlayerStats) -> Bool {
        switch self {
        case .batting: (s.batting?.pa ?? 0) > 0
        case .fielding: (s.fielding?.tc ?? 0) > 0
        case .pitching: (s.pitching?.outs ?? 0) > 0 || (s.pitching?.bf ?? 0) > 0
        case .catching: (s.fielding?.catcherOuts ?? 0) > 0
        }
    }

    /// Every number the import keeps for this group, the headline rates first.
    var columns: [StatColumn] {
        switch self {
        case .batting:
            let b = { (s: PlayerStats) in s.batting }
            return [
                .rate("AVG") { b($0)?.avg }, .rate("OBP", isDefaultSort: true) { b($0)?.obp }, .rate("SLG") { b($0)?.slg },
                .count("GP") { b($0)?.gp }, .count("PA") { b($0)?.pa }, .count("AB") { b($0)?.ab }, .count("H") { b($0)?.h },
                .count("1B") { b($0)?.singles }, .count("2B") { b($0)?.doubles }, .count("3B") { b($0)?.triples }, .count("HR") { b($0)?.hr },
                .count("R") { b($0)?.r }, .count("RBI") { b($0)?.rbi }, .count("BB") { b($0)?.bb }, .count("SO", higherIsBetter: false) { b($0)?.so },
                .count("HBP") { b($0)?.hbp }, .count("SB") { b($0)?.sb }, .count("CS", higherIsBetter: false) { b($0)?.cs },
                .percent("K%", higherIsBetter: false) { b($0)?.kRate }, .percent("BB%") { b($0)?.bbRate }, .percent("SB%") { b($0)?.sbPct },
            ]
        case .fielding:
            let f = { (s: PlayerStats) in s.fielding }
            return [
                .rate("FPCT", isDefaultSort: true) { f($0)?.fpct },
                .count("TC") { f($0)?.tc }, .count("PO") { f($0)?.po }, .count("A") { f($0)?.a },
                .count("E", higherIsBetter: false) { f($0)?.e }, .count("DP") { f($0)?.dp },
            ] + Position.allCases.map { position in
                StatColumn(id: position.label, higherIsBetter: true, isDefaultSort: false,
                           value: { f($0)?.innings[position].flatMap { $0 > 0 ? $0 : nil } },
                           format: { Self.innings($0) })
            }
        case .pitching:
            let p = { (s: PlayerStats) in s.pitching }
            return [
                .decimal("ERA", higherIsBetter: false, isDefaultSort: true) { p($0)?.era },
                .decimal("WHIP", higherIsBetter: false) { p($0)?.whip },
                StatColumn(id: "IP", higherIsBetter: true, isDefaultSort: false, value: { p($0).map { $0.innings } }, format: { Self.innings($0) }),
                .count("GP") { p($0)?.gp }, .count("GS") { p($0)?.gs }, .count("BF") { p($0)?.bf }, .count("#P") { p($0)?.pitches },
                .count("H", higherIsBetter: false) { p($0)?.h }, .count("R", higherIsBetter: false) { p($0)?.r },
                .count("ER", higherIsBetter: false) { p($0)?.er }, .count("BB", higherIsBetter: false) { p($0)?.bb },
                .count("SO") { p($0)?.so }, .count("HBP", higherIsBetter: false) { p($0)?.hbp },
                .percent("K/BF") { p($0)?.kPerBF },
            ]
        case .catching:
            let f = { (s: PlayerStats) in s.fielding }
            return [
                StatColumn(id: "INN", higherIsBetter: true, isDefaultSort: true, value: { f($0).map { $0.catcherInnings } }, format: { Self.innings($0) }),
                .count("PB", higherIsBetter: false) { f($0)?.passedBalls },
                .count("SB", higherIsBetter: false) { f($0)?.stolenBasesAllowed },
                .count("CS") { f($0)?.caughtStealing },
            ]
        }
    }

    /// 12, or 12⅓ written as "12.1" like a scorebook.
    static func innings(_ value: Double) -> String {
        let outs = Int((value * 3).rounded())
        return outs % 3 == 0 ? "\(outs / 3)" : "\(outs / 3).\(outs % 3)"
    }
}

struct StatColumn: Identifiable {
    let id: String
    let higherIsBetter: Bool
    let isDefaultSort: Bool
    let value: (PlayerStats) -> Double?
    let format: (Double) -> String

    func text(_ stats: PlayerStats) -> String { value(stats).map(format) ?? "–" }

    static func count(_ id: String, higherIsBetter: Bool = true, _ get: @escaping (PlayerStats) -> Int?) -> StatColumn {
        StatColumn(id: id, higherIsBetter: higherIsBetter, isDefaultSort: false, value: { get($0).map(Double.init) }, format: { "\(Int($0))" })
    }

    static func rate(_ id: String, isDefaultSort: Bool = false, _ get: @escaping (PlayerStats) -> Double?) -> StatColumn {
        StatColumn(id: id, higherIsBetter: true, isDefaultSort: isDefaultSort, value: get, format: { Fmt.rate($0) })
    }

    static func percent(_ id: String, higherIsBetter: Bool = true, _ get: @escaping (PlayerStats) -> Double?) -> StatColumn {
        StatColumn(id: id, higherIsBetter: higherIsBetter, isDefaultSort: false, value: get, format: { Fmt.pct($0) })
    }

    static func decimal(_ id: String, higherIsBetter: Bool, isDefaultSort: Bool = false, _ get: @escaping (PlayerStats) -> Double?) -> StatColumn {
        StatColumn(id: id, higherIsBetter: higherIsBetter, isDefaultSort: isDefaultSort, value: get, format: { Fmt.two($0) })
    }
}
