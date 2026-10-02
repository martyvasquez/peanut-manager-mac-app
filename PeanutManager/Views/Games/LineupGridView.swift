import SwiftUI
import LineupKit

/// The hero view: batting order down the side, innings across the top.
/// Click a cell to pick a position. Keyboard: arrows move · 1–9 assign by scorebook number (1 = P … 9 = RF) · 0 or B = bench ·
/// Space = lock/unlock · ⌥↑/⌥↓ = move in batting order. Drag a name to reorder.
struct LineupGridView: View {
    @Bindable var model: GameModel
    @Environment(\.undoManager) private var undoManager
    @State private var selected: CellKey?
    @State private var editing: CellKey?
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 600
    @State private var dragging: PlayerID?
    @State private var dropTarget: PlayerID?
    @State private var hovered: CellKey?

    // Sized to fill the available width, within comfortable limits.
    private var nameWidth: CGFloat { min(max(width * 0.26, 200), 280) }
    private let sitWidth: CGFloat = 52
    private var cellWidth: CGFloat {
        let innings = CGFloat(max(model.game.innings, 1))
        return min(max((width - nameWidth - sitWidth) / innings, 54), 120)
    }
    private let rowHeight: CGFloat = 46

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
                .overlay(alignment: dropLineEdge(for: player.id, rows: rows)) {
                    if dropTarget == player.id && dragging != player.id {
                        Capsule().fill(Color.accentColor).frame(height: 3).offset(y: dropLineEdge(for: player.id, rows: rows) == .top ? -1.5 : 1.5)
                    }
                }
                .opacity(present ? 1 : 0.4)
                .onDrop(of: [.plainText], isTargeted: Binding(get: { dropTarget == player.id }, set: { dropTarget = $0 ? player.id : (dropTarget == player.id ? nil : dropTarget) })) { _ in
                    defer { dragging = nil; dropTarget = nil }
                    guard let dragging, dragging != player.id else { return false }
                    withAnimation(.snappy) { model.moveBatter(dragging, to: player.id, undoManager: undoManager) }
                    return true
                }
            }
        }
        .frame(width: nameWidth + cellWidth * CGFloat(max(innings, 1)) + sitWidth, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: handleKey)
        #if DEBUG
        .task(id: model.hasGrid) {
            if UserDefaults.standard.bool(forKey: "PMOpenPicker"), model.hasGrid, rows.count > 1 {
                try? await Task.sleep(for: .milliseconds(400))
                editing = CellKey(inning: 1, player: rows[2].id)
            }
        }
        #endif
        .onTapGesture { focused = true }
    }

    // MARK: - Pieces

    private func header(innings: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: nameWidth, height: 1)
            ForEach(1...max(innings, 1), id: \.self) { inning in
                let locked = model.isInningLocked(inning)
                Button {
                    model.toggleInningLock(inning, undoManager: undoManager)
                } label: {
                    HStack(spacing: 3) {
                        Text("\(inning)")
                        if locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    }
                    .font(.callout.monospacedDigit())
                    .frame(width: cellWidth, height: 30)
                    .foregroundStyle(locked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!model.isFilled)
                .help(inningHelp(inning, locked: locked))
            }
            Text("Sit").font(.callout).foregroundStyle(.tertiary)
                .frame(width: sitWidth)
        }
    }

    /// Dragging down drops below the target row; dragging up drops above it.
    private func dropLineEdge(for target: PlayerID, rows: [PlayerSnapshot]) -> Alignment {
        guard let dragging,
              let from = rows.firstIndex(where: { $0.id == dragging }),
              let to = rows.firstIndex(where: { $0.id == target }) else { return .top }
        return from < to ? .bottom : .top
    }

    private func inningHelp(_ inning: Int, locked: Bool) -> String {
        let reason = model.document.inningReasons.indices.contains(inning - 1) ? model.document.inningReasons[inning - 1] : ""
        let action = locked ? "Click to unlock inning \(inning)." : "Click to lock inning \(inning) so regenerating keeps it."
        return reason.isEmpty ? action : "\(reason)\n\n\(action)"
    }

    private func nameCell(_ player: PlayerSnapshot, slot: Int, present: Bool) -> some View {
        HStack(spacing: 12) {
            Text(model.lineup.battingOrder.contains(player.id) ? "\(slot)" : "")
                .font(.title3.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
            Text(player.name).font(.title3).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(width: nameWidth, height: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onDrag {
            dragging = player.id
            return NSItemProvider(object: player.id.uuidString as NSString)
        } preview: {
            Text(player.name).font(.title3).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
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
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                      : problem ? AnyShapeStyle(Color.red.opacity(0.12))
                      : (!model.isFilled && model.hasGrid && available) ? AnyShapeStyle(.quaternary.opacity(hovered == key ? 0.8 : 0.35))
                      : AnyShapeStyle(Color.clear))
            if provenance == .appAdjusted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            if slot == nil && available && model.hasGrid && !model.isFilled && hovered == key {
                Image(systemName: "plus").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(label(slot: slot, available: available))
                .font(.title3.weight(slot == .field(.p) ? .semibold : .regular))
                .foregroundStyle(textStyle(slot: slot, problem: problem))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
            }
        }
        .frame(width: cellWidth - 6, height: rowHeight - 8)
        .frame(width: cellWidth, height: rowHeight)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
        .onTapGesture {
            selected = key
            focused = true
            if available && model.hasGrid { editing = key }
        }
        .popover(isPresented: Binding(get: { editing == key }, set: { if !$0 { editing = nil } })) {
            PositionPicker(model: model, player: player, inning: inning) { slot in
                model.assign(player.id, to: slot, inning: inning, undoManager: undoManager)
                editing = nil
            }
        }
        .contextMenu {
            if available && model.hasGrid {
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
        return Text(model.isFilled ? "\(sit)" : "")
            .font(.title3.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: sitWidth)
    }

    private func label(slot: Slot?, available: Bool) -> String {
        guard available else { return "·" }
        switch slot {
        case .field(let p): return p.label
        case .bench: return "–"
        case nil: return model.isFilled ? "?" : ""
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
            if model.hasGrid { editing = current }; return .handled
        default:
            guard model.hasGrid, model.context.availability(of: current.player).isAvailable(inning: current.inning) else { return .ignored }
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
        let current = assignment.slot(of: player.id)
        VStack(spacing: 10) {
            Text("\(player.name) · Inning \(inning)").font(.headline)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow { tile(.lf, assignment, current); tile(.cf, assignment, current); tile(.rf, assignment, current) }
                GridRow { tile(.third, assignment, current); tile(.ss, assignment, current); tile(.second, assignment, current) }
                GridRow { tile(.p, assignment, current); tile(.first, assignment, current); tile(.c, assignment, current) }
            }
            Button { onPick(.bench) } label: {
                Text("Sit")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .foregroundStyle(current == .bench ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .background(current == .bench ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 290)
    }

    /// Open = bright. Taken = greyed with who has it (click to swap). Theirs now = orange. Can't = struck out.
    private func tile(_ position: Position, _ assignment: InningAssignment, _ current: Slot?) -> some View {
        let holder = assignment.positions[position].flatMap { $0 == player.id ? nil : $0 }
        let fit = player.profile[position]
        let mine = current == .field(position)
        let taken = holder != nil
        let holderName = holder.map { model.context.name($0).components(separatedBy: " ").first ?? "" }

        return Button { onPick(.field(position)) } label: {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    if fit >= .good { Image(systemName: "star.fill").font(.system(size: 8)) }
                    Text(position.label).strikethrough(!fit.isEligible)
                }
                .font(.headline)
                if let holderName {
                    Text(holderName).font(.caption2).lineLimit(1)
                }
            }
            .frame(width: 80, height: 44)
            .foregroundStyle(
                mine ? AnyShapeStyle(Color.white)
                : !fit.isEligible ? AnyShapeStyle(.quaternary)
                : taken ? AnyShapeStyle(.tertiary)
                : AnyShapeStyle(.primary)
            )
            .background(
                mine ? AnyShapeStyle(Color.accentColor)
                : !fit.isEligible ? AnyShapeStyle(Color.clear)
                : taken ? AnyShapeStyle(Color.primary.opacity(0.04))
                : AnyShapeStyle(Color.primary.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(!fit.isEligible ? Color.secondary.opacity(0.2) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!fit.isEligible || mine)
        .help(!fit.isEligible ? "\(player.name) doesn't play \(position.label)"
              : mine ? "\(player.name) is at \(position.label)"
              : holderName.map { "Swap with \($0)" } ?? "Put \(player.name) at \(position.label)")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
