import SwiftUI
import LineupKit

/// The hero view: batting order down the side, innings across the top.
/// Click a cell to pick a position. Keyboard: arrows move · 1–9 assign by scorebook number (1 = P … 9 = RF) · 0 or B = bench ·
/// Space = lock/unlock · ⌥↑/⌥↓ = move in batting order.
struct LineupGridView: View {
    @Bindable var model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var selected: CellKey?
    @State private var editing: CellKey?
    @FocusState private var focused: Bool

    private let nameWidth: CGFloat = 180
    private let cellWidth: CGFloat = 46
    private let rowHeight: CGFloat = 32

    var body: some View {
        let rows = model.rows
        let innings = model.game.innings
        let problems = problemCells
        let ctx = model.context

        VStack(alignment: .leading, spacing: 0) {
            header(innings: innings)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, player in
                let present = ctx.availability(of: player.id).present
                HStack(spacing: 0) {
                    nameCell(player, slot: index + 1, present: present)
                    ForEach(1...max(innings, 1), id: \.self) { inning in
                        cell(player: player, inning: inning, problem: problems.contains(CellKey(inning: inning, player: player.id)), ctx: ctx)
                    }
                    tally(player, innings: innings)
                }
                .frame(height: rowHeight)
                .overlay(alignment: .bottom) { Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5) }
                .opacity(present ? 1 : 0.4)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: handleKey)
        .onTapGesture { focused = true }
    }

    // MARK: - Pieces

    private func header(innings: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: nameWidth)
            ForEach(1...max(innings, 1), id: \.self) { inning in
                let locked = model.isInningLocked(inning)
                Button {
                    model.toggleInningLock(inning, undoManager: undoManager)
                } label: {
                    HStack(spacing: 3) {
                        Text("\(inning)")
                        if locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    }
                    .font(.caption.monospacedDigit())
                    .frame(width: cellWidth, height: 24)
                    .foregroundStyle(locked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!model.hasDefense)
                .help(inningHelp(inning, locked: locked))
            }
            Text("Sit").font(.caption).foregroundStyle(.tertiary)
                .frame(width: 40)
        }
    }

    private func inningHelp(_ inning: Int, locked: Bool) -> String {
        let reason = model.document.inningReasons.indices.contains(inning - 1) ? model.document.inningReasons[inning - 1] : ""
        let action = locked ? "Click to unlock inning \(inning)." : "Click to lock inning \(inning) so regenerating keeps it."
        return reason.isEmpty ? action : "\(reason)\n\n\(action)"
    }

    private func nameCell(_ player: PlayerSnapshot, slot: Int, present: Bool) -> some View {
        HStack(spacing: 10) {
            Text(model.lineup.battingOrder.contains(player.id) ? "\(slot)" : "")
                .font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
            Text(player.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(width: nameWidth, alignment: .leading)
        .help(model.document.battingReasons[player.id] ?? "")
        .contextMenu {
            Button("Move Up") { model.moveBatter(player.id, by: -1, undoManager: undoManager) }
            Button("Move Down") { model.moveBatter(player.id, by: 1, undoManager: undoManager) }
        }
    }

    private func cell(player: PlayerSnapshot, inning: Int, problem: Bool, ctx: GameContext) -> some View {
        let key = CellKey(inning: inning, player: player.id)
        let available = ctx.availability(of: player.id).isAvailable(inning: inning)
        let slot = model.lineup.slot(of: player.id, inning: inning)
        let locked = model.isLocked(key)
        let provenance = model.document.provenance[key]
        let isSelected = selected == key

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (problem ? Color.red.opacity(0.12) : Color.clear))
            if provenance == .appAdjusted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            Text(label(slot: slot, available: available))
                .font(.callout.weight(slot == .field(.p) ? .semibold : .regular))
                .foregroundStyle(textStyle(slot: slot, problem: problem))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 6)).foregroundStyle(.secondary).padding(3)
            }
        }
        .frame(width: cellWidth - 4, height: rowHeight - 6)
        .frame(width: cellWidth, height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = key
            focused = true
            if available && model.hasDefense { editing = key }
        }
        .popover(isPresented: Binding(get: { editing == key }, set: { if !$0 { editing = nil } })) {
            PositionPicker(model: model, player: player, inning: inning) { slot in
                model.assign(player.id, to: slot, inning: inning, undoManager: undoManager)
                editing = nil
            }
        }
        .contextMenu {
            if available && model.hasDefense {
                ForEach(Position.allCases, id: \.self) { position in
                    Button(position.label) { model.assign(player.id, to: .field(position), inning: inning, undoManager: undoManager) }
                }
                Button("Sit") { model.assign(player.id, to: .bench, inning: inning, undoManager: undoManager) }
                Divider()
                Button(locked ? "Unlock" : "Lock") { model.toggleLock(key, undoManager: undoManager) }
            }
        }
        .help(cellHelp(provenance: provenance, locked: locked))
    }

    private func tally(_ player: PlayerSnapshot, innings: Int) -> some View {
        let slots = (1...max(innings, 1)).map { model.lineup.slot(of: player.id, inning: $0) }
        let field = slots.filter { if case .field = $0 { true } else { false } }.count
        let sit = slots.filter { $0 == .bench }.count
        _ = field
        return Text(model.hasDefense ? "\(sit)" : "")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 40)
    }

    private func label(slot: Slot?, available: Bool) -> String {
        guard available else { return "·" }
        switch slot {
        case .field(let p): return p.label
        case .bench: return "–"
        case nil: return model.hasDefense ? "?" : ""
        }
    }

    private func textStyle(slot: Slot?, problem: Bool) -> AnyShapeStyle {
        if problem { return AnyShapeStyle(Color.red) }
        switch slot {
        case .field: return AnyShapeStyle(.primary)
        default: return AnyShapeStyle(.quaternary)
        }
    }

    private func cellHelp(provenance: Provenance?, locked: Bool) -> String {
        var parts: [String] = []
        switch provenance {
        case .coach: parts.append("Set by you")
        case .appAdjusted: parts.append("Adjusted by the app after the AI couldn't fix a rule problem")
        case .aiRevised: parts.append("AI (revised after a rule check)")
        case .ai: parts.append("AI")
        case nil: break
        }
        if locked { parts.append("Locked — regenerating keeps it") }
        return parts.joined(separator: " · ")
    }

    private var problemCells: Set<CellKey> {
        var cells = Set<CellKey>()
        for finding in model.findings where finding.severity == .violation {
            if let inning = finding.inning, let player = finding.player { cells.insert(CellKey(inning: inning, player: player)) }
            if let inning = finding.inning, let position = finding.position, finding.player == nil,
               let holder = model.lineup.innings[safe: inning - 1]?.positions[position] {
                cells.insert(CellKey(inning: inning, player: holder))
            }
        }
        return cells
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let rows = model.rows
        guard !rows.isEmpty else { return .ignored }
        var current = selected ?? CellKey(inning: 1, player: rows[0].id)
        guard let row = rows.firstIndex(where: { $0.id == current.player }) else { return .ignored }

        switch press.key {
        case .upArrow where press.modifiers.contains(.option):
            model.moveBatter(current.player, by: -1, undoManager: undoManager); return .handled
        case .downArrow where press.modifiers.contains(.option):
            model.moveBatter(current.player, by: 1, undoManager: undoManager); return .handled
        case .upArrow: current.player = rows[max(row - 1, 0)].id
        case .downArrow: current.player = rows[min(row + 1, rows.count - 1)].id
        case .leftArrow: current.inning = max(current.inning - 1, 1)
        case .rightArrow: current.inning = min(current.inning + 1, model.game.innings)
        case .space:
            model.toggleLock(current, undoManager: undoManager); return .handled
        case .return:
            if model.hasDefense { editing = current }; return .handled
        default:
            guard model.hasDefense, model.context.availability(of: current.player).isAvailable(inning: current.inning) else { return .ignored }
            let ch = press.characters.lowercased()
            if let n = Int(ch), (1...9).contains(n) {
                model.assign(current.player, to: .field(Position.allCases[n - 1]), inning: current.inning, undoManager: undoManager)
                return .handled
            }
            if ch == "0" || ch == "b" || ch == "-" {
                model.assign(current.player, to: .bench, inning: current.inning, undoManager: undoManager)
                return .handled
            }
            return .ignored
        }
        selected = current
        return .handled
    }
}

/// Popover for picking a position, laid out like the field.
struct PositionPicker: View {
    let model: GameModel
    let player: PlayerSnapshot
    let inning: Int
    var onPick: (Slot) -> Void

    var body: some View {
        let assignment = model.lineup.innings[safe: inning - 1] ?? InningAssignment()
        VStack(spacing: 8) {
            Text("\(player.name) · Inning \(inning)").font(.headline)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow { button(.lf, assignment); button(.cf, assignment); button(.rf, assignment) }
                GridRow { button(.third, assignment); button(.ss, assignment); button(.second, assignment) }
                GridRow { button(.p, assignment); button(.first, assignment); button(.c, assignment) }
            }
            Button { onPick(.bench) } label: {
                Text("Sit").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(width: 290)
    }

    private func button(_ position: Position, _ assignment: InningAssignment) -> some View {
        let holder = assignment.positions[position]
        let fit = player.profile[position]
        return Button { onPick(.field(position)) } label: {
            VStack(spacing: 1) {
                Text(position.label).font(.headline.monospaced())
                Text(holder.map { model.context.name($0).components(separatedBy: " ").first ?? "" } ?? "open")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 78, height: 38)
        }
        .disabled(!fit.isEligible)
        .help(fit.isEligible ? "\(player.name): \(fit.label)" : "\(player.name) is marked Can't for \(position.label)")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
