import SwiftUI
import LineupKit

/// The hero view: batting order down the side, innings across the top.
/// Keyboard: arrows move · 1–9 assign by scorebook number (1 = P … 9 = RF) · 0 or B = bench ·
/// Space = lock/unlock · ⌥↑/⌥↓ = move in batting order.
struct LineupGridView: View {
    @Bindable var model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var selected: CellKey?
    @State private var editing: CellKey?
    @FocusState private var focused: Bool

    private let nameWidth: CGFloat = 170
    private let cellWidth: CGFloat = 50
    private let rowHeight: CGFloat = 30

    var body: some View {
        let rows = model.rows
        let innings = model.game.innings
        let problems = problemCells
        let ctx = model.context

        VStack(alignment: .leading, spacing: 0) {
            header(innings: innings)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, player in
                let present = ctx.availability(of: player.id).present
                HStack(spacing: 0) {
                    nameCell(player, slot: index + 1, present: present)
                    ForEach(1...max(innings, 1), id: \.self) { inning in
                        cell(player: player, inning: inning, problem: problems.contains(CellKey(inning: inning, player: player.id)))
                    }
                    tally(player, innings: innings)
                }
                .frame(height: rowHeight)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                .opacity(present ? 1 : 0.45)
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
            Text("Batting Order").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: nameWidth, alignment: .leading).padding(.leading, 8)
            ForEach(1...max(innings, 1), id: \.self) { inning in
                let locked = model.isInningLocked(inning)
                Button {
                    model.toggleInningLock(inning, undoManager: undoManager)
                } label: {
                    HStack(spacing: 3) {
                        Text("\(inning)")
                        if locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(width: cellWidth, height: 26)
                    .foregroundStyle(locked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasDefense)
                .help(inningHelp(inning, locked: locked))
            }
            Text("Field / Sit").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 64)
        }
    }

    private func inningHelp(_ inning: Int, locked: Bool) -> String {
        let reason = model.document.inningReasons.indices.contains(inning - 1) ? model.document.inningReasons[inning - 1] : ""
        let action = locked ? "Click to unlock inning \(inning)." : "Click to lock inning \(inning) so regenerating keeps it."
        return reason.isEmpty ? action : "\(reason)\n\n\(action)"
    }

    private func nameCell(_ player: PlayerSnapshot, slot: Int, present: Bool) -> some View {
        HStack(spacing: 6) {
            Text(model.lineup.battingOrder.contains(player.id) ? "\(slot)" : "–")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            Text(player.jersey.map { "#\($0)" } ?? "").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 30, alignment: .leading)
            Text(player.name).lineLimit(1)
            if !present { Text("Not here").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .frame(width: nameWidth, alignment: .leading)
        .help(model.document.battingReasons[player.id] ?? "")
        .contextMenu {
            Button("Move Up") { model.moveBatter(player.id, by: -1, undoManager: undoManager) }
            Button("Move Down") { model.moveBatter(player.id, by: 1, undoManager: undoManager) }
        }
    }

    private func cell(player: PlayerSnapshot, inning: Int, problem: Bool) -> some View {
        let key = CellKey(inning: inning, player: player.id)
        let available = model.context.availability(of: player.id).isAvailable(inning: inning)
        let slot = model.lineup.slot(of: player.id, inning: inning)
        let locked = model.isLocked(key)
        let provenance = model.document.provenance[key]
        let isSelected = selected == key

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill(slot: slot, problem: problem, locked: locked))
            if provenance == .appAdjusted {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange, lineWidth: 1.5)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2)
            }
            Text(label(slot: slot, available: available))
                .font(.callout.weight(slot == .field(.p) || slot == .field(.c) ? .bold : .medium).monospaced())
                .foregroundStyle(slot == .bench || slot == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 7)).foregroundStyle(Color.accentColor).padding(3)
            }
        }
        .frame(width: cellWidth - 6, height: rowHeight - 6)
        .frame(width: cellWidth, height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if available && model.hasDefense { selected = key; editing = key } }
        .onTapGesture { selected = key; focused = true }
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
        return Text(model.hasDefense ? "\(field) / \(sit)" : "")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 64)
    }

    private func label(slot: Slot?, available: Bool) -> String {
        guard available else { return "·" }
        switch slot {
        case .field(let p): return p.label
        case .bench: return "—"
        case nil: return model.hasDefense ? "?" : ""
        }
    }

    private func fill(slot: Slot?, problem: Bool, locked: Bool) -> Color {
        if problem { return Color.red.opacity(0.18) }
        if locked { return Color.accentColor.opacity(0.12) }
        switch slot {
        case .field(let p) where p.isInfield: return Color.primary.opacity(0.06)
        case .field: return Color.green.opacity(0.08)
        default: return Color.clear
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
            Text("Picking a taken spot swaps the two players. Your pick is locked.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
