import SwiftUI
import AppKit
import LineupKit

/// The hero view: batting order down the side, innings across the top.
/// Click a cell to pick a position. Keyboard: arrows move · 1–9 assign by scorebook number (1 = P … 9 = RF) · 0 or B = bench ·
/// Space = lock/unlock · ⌥↑/⌥↓ = move in batting order. Drag a name to reorder, a spot onto another in the same inning to swap,
/// an inning number to move the inning. The inning's menu copies and pastes, adds, locks or deletes.
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
    @State private var draggingCell: CellKey?
    @State private var cellTarget: CellKey?
    @State private var draggingInning: Int?
    @State private var inningTarget: Int?
    @State private var hoveredInning: Int?
    @State private var hoveredRow: PlayerID?
    @State private var diamondInning: Int?

    // Sized to fill the available width, within comfortable limits.
    private var nameWidth: CGFloat { min(max(width * 0.26, 200), 280) }
    private var cellWidth: CGFloat {
        let innings = CGFloat(max(model.game.innings, 1))
        return min(max((width - nameWidth) / innings, 54), 120)
    }
    private let rowHeight: CGFloat = 46
    /// Locks tell the AI what to keep; without AI there's nothing to keep them from.
    private var showsLocks: Bool { AIService.shared.isReady }

    var body: some View {
        let rows = model.rows
        let innings = model.game.innings
        let problems = problemCells
        let ctx = model.context
        // Hovering a spot lights up that position in every inning, so you can follow who plays it.
        let litPosition: Position? = hovered.flatMap { key in
            if case .field(let position)? = model.lineup.slot(of: key.player, inning: key.inning) { position } else { nil }
        }

        VStack(alignment: .leading, spacing: 0) {
            header(innings: innings)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, player in
                let present = ctx.availability(of: player.id).present
                HStack(spacing: 0) {
                    nameCell(player, slot: index + 1, present: present)
                    ForEach(1...max(innings, 1), id: \.self) { inning in
                        cell(player: player, inning: inning, problem: problems.contains(CellKey(inning: inning, player: player.id)), lit: litPosition, ctx: ctx)
                    }
                }
                .frame(height: rowHeight)
                .background(hoveredRow == player.id ? AnyShapeStyle(Color.primary.opacity(0.04)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 8))
                .onHover { inside in hoveredRow = inside ? player.id : (hoveredRow == player.id ? nil : hoveredRow) }
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
        .frame(width: nameWidth + cellWidth * CGFloat(max(innings, 1)), alignment: .leading)
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
            let hover = UserDefaults.standard.integer(forKey: "PMHoverInning")
            if hover > 0 { hoveredInning = hover }
            let diamond = UserDefaults.standard.integer(forKey: "PMDiamond")
            if diamond > 0, model.hasGrid { try? await Task.sleep(for: .milliseconds(400)); diamondInning = diamond }
        }
        #endif
        .onTapGesture { focused = true }
    }

    // MARK: - Pieces

    private func header(innings: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: nameWidth, height: 1)
            ForEach(1...max(innings, 1), id: \.self) { inning in
                inningHeader(inning, innings: innings)
            }
        }
    }

    /// The inning's number: click to see it on the field, drag to move the inning, or open its menu (hover, or right-click).
    private func inningHeader(_ inning: Int, innings: Int) -> some View {
        let locked = showsLocks && model.isInningLocked(inning)
        let edge: Alignment = (draggingInning ?? 0) < inning ? .trailing : .leading
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Text("\(inning)")
                if locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(locked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .frame(width: cellWidth, height: 30)
            .overlay(alignment: .trailing) {
                if hoveredInning == inning && draggingInning == nil {
                    Menu { inningMenu(inning, innings: innings, locked: locked) } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.trailing, 6)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in hoveredInning = inside ? inning : (hoveredInning == inning ? nil : hoveredInning) }
            .onTapGesture { if model.hasGrid { diamondInning = inning } }
            .popover(isPresented: Binding(get: { diamondInning == inning }, set: { if !$0 { diamondInning = nil } }), arrowEdge: .bottom) {
                InningDiamond(model: model, inning: inning, undoManager: undoManager)
            }
            .onDrag {
                dragging = nil; draggingCell = nil
                draggingInning = inning
                return NSItemProvider(object: "inning \(inning)" as NSString)
            } preview: {
                Text("Inning \(inning)").font(.title3).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .onDrop(of: [.plainText], isTargeted: Binding(
                get: { inningTarget == inning },
                set: { inside in if draggingInning != nil { inningTarget = inside ? inning : (inningTarget == inning ? nil : inningTarget) } }
            )) { _ in dropInning(on: inning) }
            .overlay(alignment: edge) {
                if inningTarget == inning, let from = draggingInning, from != inning {
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 22)
                }
            }
            .contextMenu { inningMenu(inning, innings: innings, locked: locked) }
            .help(inningHelp(inning))
            if model.hasGrid && !model.isFilled {
                Text(openLabel(inning))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: cellWidth - 4, height: 16)
            }
        }
    }

    @ViewBuilder
    private func inningMenu(_ inning: Int, innings: Int, locked: Bool) -> some View {
        Button("Copy Inning") { model.copyInning(inning) }
        Button("Paste Inning") { withAnimation(.snappy) { model.pasteInning(into: inning, undoManager: undoManager) } }
            .disabled(GameModel.copiedInning == nil)
        Divider()
        Button("Add Inning Before") { withAnimation(.snappy) { model.insertInning(at: inning, undoManager: undoManager) } }
        Button("Add Inning After") { withAnimation(.snappy) { model.insertInning(at: inning + 1, undoManager: undoManager) } }
        if showsLocks && model.isFilled {
            Divider()
            Button(locked ? "Unlock Inning" : "Lock Inning") { model.toggleInningLock(inning, undoManager: undoManager) }
        }
        if innings > 1 {
            Divider()
            Button("Delete Inning \(inning)", role: .destructive) { withAnimation(.snappy) { model.removeInning(inning, undoManager: undoManager) } }
        }
    }

    private func dropInning(on target: Int) -> Bool {
        defer { draggingInning = nil; inningTarget = nil }
        guard let from = draggingInning, from != target else { return false }
        withAnimation(.snappy) { model.moveInning(from, to: target, undoManager: undoManager) }
        Self.snap()
        return true
    }

    /// A light tap on the trackpad when a drop lands.
    static func snap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// What's still open this inning: the positions themselves when only a few are left.
    private func openLabel(_ inning: Int) -> String {
        let open = model.lineup.innings[safe: inning - 1]?.openPositions ?? Position.allCases
        switch open.count {
        case 0: return ""
        case 1...3: return open.map(\.label).joined(separator: " ")
        default: return "\(open.count) open"
        }
    }

    /// Dragging down drops below the target row; dragging up drops above it.
    private func dropLineEdge(for target: PlayerID, rows: [PlayerSnapshot]) -> Alignment {
        guard let dragging,
              let from = rows.firstIndex(where: { $0.id == dragging }),
              let to = rows.firstIndex(where: { $0.id == target }) else { return .top }
        return from < to ? .bottom : .top
    }

    private func inningHelp(_ inning: Int) -> String {
        let reason = model.document.inningReasons.indices.contains(inning - 1) ? model.document.inningReasons[inning - 1] : ""
        let action = "Click to see inning \(inning) on the field · drag to move it"
        return reason.isEmpty ? action : "\(reason)\n\n\(action)"
    }

    private func nameCell(_ player: PlayerSnapshot, slot: Int, present: Bool) -> some View {
        HStack(spacing: 12) {
            Text(model.lineup.battingOrder.contains(player.id) ? "\(slot)" : "")
                .font(.title3.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
            Text(player.name).font(.title3).lineLimit(1)
            Spacer(minLength: 0)
            if hoveredRow == player.id && model.lineup.battingOrder.contains(player.id) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).padding(.trailing, 12)
            }
        }
        .frame(width: nameWidth, height: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onDrag {
            draggingCell = nil; draggingInning = nil
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

    private func cell(player: PlayerSnapshot, inning: Int, problem: Bool, lit: Position?, ctx: GameContext) -> some View {
        let key = CellKey(inning: inning, player: player.id)
        let available = ctx.availability(of: player.id).isAvailable(inning: inning)
        let slot = model.lineup.slot(of: player.id, inning: inning)
        let locked = showsLocks && model.isLocked(key)
        let provenance = model.document.provenance[key]
        let isSelected = selected == key

        let swapTarget = cellTarget == key && draggingCell.map { $0.inning == inning && model.canSwap($0.player, player.id, inning: inning) } == true
        let isLit = lit != nil && slot == .field(lit!)
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(swapTarget ? AnyShapeStyle(Color.accentColor.opacity(0.3))
                      : isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                      : problem ? AnyShapeStyle(Color.red.opacity(0.12))
                      : isLit ? AnyShapeStyle(Color.accentColor.opacity(0.12))
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
                .font(slot == .bench ? .callout.weight(.medium) : .title3.weight(slot == .field(.p) ? .semibold : .regular))
                .foregroundStyle(isLit && !problem ? AnyShapeStyle(Color.accentColor) : textStyle(slot: slot, problem: problem))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
            }
        }
        .frame(width: cellWidth - 6, height: rowHeight - 8)
        .scaleEffect(swapTarget ? 1.06 : 1)
        .opacity(draggingCell == key ? 0.35 : 1)
        .frame(width: cellWidth, height: rowHeight)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
        .onDrag {
            dragging = nil; draggingInning = nil
            draggingCell = key
            return NSItemProvider(object: "\(player.id.uuidString) \(inning)" as NSString)
        } preview: {
            Text("\(label(slot: slot, available: available)) · \(player.name.components(separatedBy: " ").first ?? "")")
                .font(.title3).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .onDrop(of: [.plainText], isTargeted: Binding(
            get: { cellTarget == key },
            set: { inside in
                if draggingCell != nil {
                    cellTarget = inside ? key : (cellTarget == key ? nil : cellTarget)
                } else if dragging != nil {
                    dropTarget = inside ? player.id : (dropTarget == player.id ? nil : dropTarget)
                }
            }
        )) { _ in dropOnCell(key) }
        .animation(.snappy(duration: 0.18), value: swapTarget)
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
                if showsLocks {
                    Divider()
                    Button(locked ? "Unlock" : "Lock") { model.toggleLock(key, undoManager: undoManager) }
                }
            }
        }
        .help(cellHelp(provenance: provenance, locked: locked))
    }

    /// Drops on a spot: another spot in the same inning swaps the two kids; a name moves that batter here.
    private func dropOnCell(_ key: CellKey) -> Bool {
        defer { draggingCell = nil; cellTarget = nil; dragging = nil; dropTarget = nil }
        if let from = draggingCell {
            guard from.inning == key.inning, model.canSwap(from.player, key.player, inning: key.inning) else { return false }
            withAnimation(.snappy) { model.swap(from.player, key.player, inning: key.inning, undoManager: undoManager) }
            Self.snap()
            return true
        }
        if let dragging, dragging != key.player {
            withAnimation(.snappy) { model.moveBatter(dragging, to: key.player, undoManager: undoManager) }
            return true
        }
        return false
    }

    private func label(slot: Slot?, available: Bool) -> String {
        guard available else { return "·" }
        switch slot {
        case .field(let p): return p.label
        case .bench: return "SIT"
        case nil: return model.isFilled ? "?" : ""
        }
    }

    private func textStyle(slot: Slot?, problem: Bool) -> AnyShapeStyle {
        if problem { return AnyShapeStyle(Color.red) }
        switch slot {
        case .field: return AnyShapeStyle(.primary)
        case .bench: return AnyShapeStyle(.secondary)
        case nil: return AnyShapeStyle(.quaternary)
        }
    }

    private func cellHelp(provenance: Provenance?, locked: Bool) -> String {
        var parts: [String] = []
        switch provenance {
        case .coach: parts.append("Set by you")
        case .appAdjusted: parts.append("Changed by the app: the AI couldn’t fix a rule problem, so the app did")
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
