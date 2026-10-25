import SwiftUI
import LineupKit

/// Step 2 on a phone: the whole grid on one screen, and below it either the picked spot's positions (the tray)
/// or one inning on the field. Tap a spot to pick its position; with a spot picked, tap another spot in the same
/// inning to swap the two. Tap an inning's number to see it on the field.
struct PositionsBoard: View {
    let model: GameModel
    /// Fill the Rest: the AI fills every spot the coach hasn't placed.
    let fill: () -> Void
    @State private var selected: CellKey?
    @State private var fieldInning = 1
    @State private var swaps = 0

    private let panelHeight: CGFloat = 246
    private let headerHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let rows = model.rows
            // Rows sized so the whole game fits above the panel; small phones scroll.
            let fit = (geo.size.height - panelHeight - headerHeight - 8) / CGFloat(max(rows.count, 1))
            VStack(spacing: 0) {
                ScrollView {
                    PositionsGrid(model: model, selected: $selected, fieldInning: $fieldInning, swaps: $swaps,
                                  width: geo.size.width - 24, rowHeight: min(max(fit, 34), 48), headerHeight: headerHeight)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                panel.frame(height: panelHeight)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: swaps)
        .sensoryFeedback(.selection, trigger: selected)
        .onAppear(perform: debugSetup)
    }

    private var panel: some View {
        Group {
            if model.isGenerating {
                Progress(status: model.status) { model.cancel() }
                    .padding(.top, 16)
                    .transition(.opacity)
            } else if let key = selected {
                PositionTray(model: model, key: key, selected: $selected)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                InningField(model: model, inning: $fieldInning, fill: fill)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background.secondary, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .ignoresSafeArea(edges: .bottom)
        .animation(.snappy(duration: 0.25), value: selected == nil)
        .animation(.snappy(duration: 0.25), value: model.isGenerating)
    }

    /// `-PMSelect 3:2` opens the tray on inning 3, row 2 (from 0), for screenshots.
    private func debugSetup() {
        #if DEBUG
        guard let spec = UserDefaults.standard.string(forKey: "PMSelect") else { return }
        let parts = spec.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let player = model.rows[safe: parts[1]] else { return }
        selected = CellKey(inning: parts[0], player: player.id)
        #endif
    }
}

// MARK: - Grid

struct PositionsGrid: View {
    let model: GameModel
    @Binding var selected: CellKey?
    @Binding var fieldInning: Int
    @Binding var swaps: Int
    let width: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    @Environment(\.undoManager) private var undoManager

    @AppStorage("gridFitsAllInnings") private var fitsAll = false

    private var innings: Int { max(model.game.innings, 1) }
    /// Up to six innings always fit. Past six there are two sizes, and a pinch picks one: comfortable cells with
    /// the later innings a swipe away (a sliver of the next one shows), or every inning on screen in narrower cells.
    private var showsAll: Bool { innings <= 6 || fitsAll }
    private var nameWidth: CGFloat { innings > 6 && fitsAll ? 88 : 96 }
    private var cellWidth: CGFloat {
        let columns = showsAll ? CGFloat(innings) : 6.35
        return min(max((width - nameWidth) / columns, showsAll ? 26 : 36), 56)
    }
    /// Narrow cells take smaller type.
    private var compact: Bool { cellWidth < 36 }
    /// Locks tell the AI what to keep; without AI there's nothing to keep them from.
    private var showsLocks: Bool { AIService.shared.isReady }

    var body: some View {
        let rows = model.rows
        let ctx = model.context
        let findings = model.findings
        let problems = problemCells(findings)
        let selectedSlot = selected.flatMap { model.lineup.slot(of: $0.player, inning: $0.inning) }
        // Names stay put; the innings scroll under them when they don't all fit.
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: headerHeight)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, player in
                    nameCell(player, order: index + 1, breaks: findings.contains { $0.severity == .violation && $0.player == player.id && $0.inning == nil })
                        .frame(height: rowHeight)
                        .opacity(ctx.availability(of: player.id).present ? 1 : 0.4)
                        .overlay(alignment: .bottom) { separator }
                }
            }
            .frame(width: nameWidth)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        header
                        ForEach(rows) { player in
                            HStack(spacing: 0) {
                                ForEach(1...innings, id: \.self) { inning in
                                    let key = CellKey(inning: inning, player: player.id)
                                    cell(key, problem: problems.contains(key), selectedSlot: selectedSlot, ctx: ctx)
                                }
                            }
                            .frame(height: rowHeight)
                            .opacity(ctx.availability(of: player.id).present ? 1 : 0.4)
                            .overlay(alignment: .bottom) { separator }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(showsAll && cellWidth * CGFloat(innings) <= width - nameWidth + 0.5)
                // The picked spot and the inning on the field stay in view.
                .onChange(of: selected?.inning) { _, inning in
                    if let inning { withAnimation(.snappy) { proxy.scrollTo(inning) } }
                }
                .onChange(of: fieldInning) { _, inning in
                    withAnimation(.snappy) { proxy.scrollTo(inning) }
                }
            }
        }
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            guard innings > 6 else { return }
            if value.magnification < 0.85, !fitsAll { withAnimation(.snappy) { fitsAll = true } }
            if value.magnification > 1.15, fitsAll { withAnimation(.snappy) { fitsAll = false } }
        })
        .sensoryFeedback(.impact(weight: .light), trigger: fitsAll)
    }

    private var separator: some View {
        Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(1...innings, id: \.self) { inning in
                let shown = selected?.inning == inning || (selected == nil && fieldInning == inning)
                Text("\(inning)")
                    .font(.subheadline.weight(shown ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(shown ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: cellWidth, height: headerHeight)
                    .id(inning)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selected = nil
                        fieldInning = inning
                    }
            }
        }
    }

    private func nameCell(_ player: PlayerSnapshot, order: Int, breaks: Bool) -> some View {
        HStack(spacing: 6) {
            Text(model.lineup.battingOrder.contains(player.id) ? "\(order)" : "")
                .font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)
            Text(player.shortName)
                .font((compact ? Font.footnote : Font.subheadline).weight(selected?.player == player.id ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(breaks ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
        }
        .frame(width: nameWidth, alignment: .leading)
    }

    private func cell(_ key: CellKey, problem: Bool, selectedSlot: Slot?, ctx: GameContext) -> some View {
        let slot = model.lineup.slot(of: key.player, inning: key.inning)
        let isSelected = selected == key
        let available = ctx.availability(of: key.player).isAvailable(inning: key.inning)
        // The picked kid's position, lit in every inning, so you can follow who plays it.
        let lit: Bool = if !isSelected, case .field? = slot, slot == selectedSlot { true } else { false }
        // With a placed spot picked, the placed spots it can't swap with in its inning fade.
        let sameInning = selected.map { $0.inning == key.inning && !isSelected } ?? false
        let faded = sameInning && selectedSlot != nil && slot != nil && !model.canSwap(selected!.player, key.player, inning: key.inning)
        let locked = showsLocks && model.isLocked(key)
        let adjusted = model.document.provenance[key] == .appAdjusted

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor)
                      : problem ? AnyShapeStyle(Color.red.opacity(0.14))
                      : lit ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                      : available ? AnyShapeStyle(.quaternary.opacity(0.5))
                      : AnyShapeStyle(Color.clear))
            if adjusted && !isSelected {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            Text(label(slot, available: available))
                .font(slot == .bench ? (compact ? .system(size: 9, weight: .semibold) : .caption.weight(.semibold))
                      : (compact ? Font.footnote : Font.subheadline).weight(slot == .field(.p) ? .bold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white)
                                 : problem ? AnyShapeStyle(Color.red)
                                 : lit ? AnyShapeStyle(Color.accentColor)
                                 : slot == .bench ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                    .padding(3)
            }
        }
        .padding(compact ? 2 : 2.5)
        .frame(width: cellWidth, height: rowHeight)
        .opacity(faded ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if available { tap(key) } }
        .contextMenu {
            if available {
                if showsLocks, slot != nil {
                    Button(locked ? "Unlock" : "Lock", systemImage: locked ? "lock.open" : "lock") { model.toggleLock(key, undoManager: undoManager) }
                }
                if slot != .bench {
                    Button("Sit", systemImage: "chair") {
                        withAnimation(.snappy) { model.assign(key.player, to: .bench, inning: key.inning, undoManager: undoManager) }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: slot)
    }

    /// First tap picks a spot. With a placed spot picked, a tap on another placed spot in its inning swaps them;
    /// anything else picks the new spot, and a second tap on the same spot lets go.
    private func tap(_ key: CellKey) {
        guard let current = selected else { selected = key; return }
        if current == key { selected = nil; return }
        let lineup = model.lineup
        if current.inning == key.inning,
           lineup.slot(of: current.player, inning: current.inning) != nil, lineup.slot(of: key.player, inning: key.inning) != nil,
           model.canSwap(current.player, key.player, inning: key.inning) {
            withAnimation(.snappy) { model.swap(current.player, key.player, inning: key.inning, undoManager: undoManager) }
            swaps += 1
            selected = nil
            return
        }
        selected = key
    }

    private func label(_ slot: Slot?, available: Bool) -> String {
        guard available else { return "·" }
        switch slot {
        case .field(let p): return p.label
        case .bench: return "SIT"
        case nil: return ""
        }
    }

    private func problemCells(_ findings: [Finding]) -> Set<CellKey> {
        var cells = Set<CellKey>()
        for finding in findings where finding.severity == .violation {
            if let inning = finding.inning, let player = finding.player { cells.insert(CellKey(inning: inning, player: player)) }
            if let inning = finding.inning, let position = finding.position, finding.player == nil,
               let holder = model.lineup.innings[safe: inning - 1]?.positions[position] {
                cells.insert(CellKey(inning: inning, player: holder))
            }
        }
        return cells
    }
}

// MARK: - Tray

/// The picked spot's choices, laid out like the field: open, taken (tap to swap), theirs now, can't play.
struct PositionTray: View {
    let model: GameModel
    let key: CellKey
    @Binding var selected: CellKey?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let player = model.context.player(key.player)
        let assignment = model.lineup.innings[safe: key.inning - 1] ?? InningAssignment()
        let current = assignment.slot(of: key.player)
        let locked = model.isLocked(key)
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                Text(player?.shortName ?? "").font(.headline)
                Text("Inning \(key.inning)").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if AIService.shared.isReady, current != nil {
                    Button(locked ? "Unlock" : "Lock", systemImage: locked ? "lock.fill" : "lock.open") { model.toggleLock(key, undoManager: undoManager) }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(locked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: 40, height: 36)
                }
                Button("Previous Inning", systemImage: "chevron.left") { step(-1) }
                    .labelStyle(.iconOnly).frame(width: 40, height: 36)
                    .disabled(key.inning <= 1)
                Button("Next Inning", systemImage: "chevron.right") { step(1) }
                    .labelStyle(.iconOnly).frame(width: 40, height: 36)
                    .disabled(key.inning >= model.game.innings)
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.plain)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { tile(.lf, assignment, current, player); tile(.cf, assignment, current, player); tile(.rf, assignment, current, player) }
                GridRow { tile(.third, assignment, current, player); tile(.ss, assignment, current, player); tile(.second, assignment, current, player) }
                GridRow { tile(.p, assignment, current, player); tile(.first, assignment, current, player); tile(.c, assignment, current, player) }
            }

            Button { pick(.bench) } label: {
                Text("Sit")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .foregroundStyle(current == .bench ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .background(current == .bench ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(current != .bench)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func tile(_ position: Position, _ assignment: InningAssignment, _ current: Slot?, _ player: PlayerSnapshot?) -> some View {
        let holder = assignment.positions[position].flatMap { $0 == key.player ? nil : model.context.player($0) }
        let fit = player?.profile[position] ?? .can
        let mine = current == .field(position)
        return Button { pick(.field(position)) } label: {
            VStack(spacing: 1) {
                HStack(spacing: 2) {
                    if fit >= .good { Image(systemName: "star.fill").font(.system(size: 9)) }
                    Text(position.label).strikethrough(!fit.isEligible)
                }
                .font(.headline)
                if let holder {
                    Text(holder.firstName).font(.caption)
                        .foregroundStyle(mine ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(mine ? AnyShapeStyle(Color.white)
                             : !fit.isEligible ? AnyShapeStyle(.quaternary)
                             : AnyShapeStyle(.primary))
            .background(mine ? AnyShapeStyle(Color.accentColor)
                        : !fit.isEligible ? AnyShapeStyle(Color.clear)
                        : AnyShapeStyle(Color.primary.opacity(holder != nil ? 0.07 : 0.14)),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(!fit.isEligible ? Color.secondary.opacity(0.25) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!fit.isEligible)
        .allowsHitTesting(!mine)
    }

    /// After a pick, the tray moves to the next kid in this inning who isn't placed yet, so an inning fills top
    /// to bottom; once everyone's placed it closes.
    private func pick(_ slot: Slot) {
        withAnimation(.snappy) { model.assign(key.player, to: slot, inning: key.inning, undoManager: undoManager) }
        let rows = model.rows.map(\.id)
        let assignment = model.lineup.innings[safe: key.inning - 1] ?? InningAssignment()
        let unplaced = Set(model.context.availablePlayers(inning: key.inning).map(\.id).filter { assignment.slot(of: $0) == nil })
        let start = rows.firstIndex(of: key.player) ?? 0
        let next = (rows[(start + 1)...] + rows[..<start]).first(where: unplaced.contains)
        selected = next.map { CellKey(inning: key.inning, player: $0) }
    }

    private func step(_ delta: Int) {
        selected = CellKey(inning: key.inning + delta, player: key.player)
    }
}

// MARK: - Inning on the field

/// One inning as the coach pictures it, with the rule status beside it. Swipe or use the arrows to step innings.
struct InningField: View {
    let model: GameModel
    @Binding var inning: Int
    let fill: () -> Void

    private let scale: CGFloat = 0.64

    var body: some View {
        let ctx = model.context
        let assignment = model.lineup.innings[safe: inning - 1] ?? InningAssignment()
        let sitting = assignment.sitting.compactMap { ctx.player($0) }
        let unplaced = ctx.availablePlayers(inning: inning).filter { assignment.slot(of: $0.id) == nil }
        let violations = model.findings.filter { $0.severity == .violation }
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button("Previous Inning", systemImage: "chevron.left") { inning -= 1 }
                    .labelStyle(.iconOnly).frame(width: 36, height: 32).disabled(inning <= 1)
                Text("Inning \(inning)").font(.headline).monospacedDigit()
                Button("Next Inning", systemImage: "chevron.right") { inning += 1 }
                    .labelStyle(.iconOnly).frame(width: 36, height: 32).disabled(inning >= model.game.innings)
                Spacer()
                status(violations)
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))

            ZStack(alignment: .topLeading) {
                FieldDrawing(scale: scale)
                ForEach(Position.allCases, id: \.self) { position in
                    let p = FieldGeometry.point(FieldGeometry.fielder[position]!)
                    spot(position, holder: assignment.positions[position].flatMap { ctx.player($0) })
                        .position(x: p.x * scale, y: p.y * scale)
                }
            }
            .frame(width: FieldGeometry.size.width * scale, height: FieldGeometry.size.height * scale)
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Text(unplaced.isEmpty ? "Sitting" : "Not Placed")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text((unplaced.isEmpty ? sitting : unplaced).map(\.firstName).joined(separator: ", "))
                    .font(.footnote).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -40, inning < model.game.innings { inning += 1 }
            if value.translation.width > 40, inning > 1 { inning -= 1 }
        })
        .animation(.snappy, value: inning)
    }

    @ViewBuilder
    private func status(_ violations: [Finding]) -> some View {
        // Until the grid is full, the next thing to do is fill it; a rule a placed spot already breaks shows in red on the grid.
        if !model.isFilled && AIService.shared.isReady {
            Button(action: fill) {
                Label(model.document.locks.isEmpty ? "Fill Positions" : "Fill the Rest", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        } else if !violations.isEmpty {
            Label("\(violations.count) rule \(violations.count == 1 ? "problem" : "problems")", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(.red)
        } else if model.isFilled {
            // Counted live, so the orange outlines on the grid explain themselves.
            let adjusted = model.document.provenance.values.filter { $0 == .appAdjusted }.count
            VStack(alignment: .trailing, spacing: 1) {
                Label("Follows your rules", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.green)
                if adjusted > 0 {
                    Text("\(adjusted) spot\(adjusted == 1 ? "" : "s") changed by the app")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } else {
            let open = model.lineup.innings.reduce(0) { $0 + $1.openPositions.count }
            Text("\(open) open").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func spot(_ position: Position, holder: PlayerSnapshot?) -> some View {
        if let holder {
            VStack(spacing: 0) {
                Text(holder.firstName).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(position.label).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.background, in: Capsule())
            .fixedSize()
        } else {
            Text(position.label)
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
    }
}

extension PlayerSnapshot {
    /// "Alex R.": enough to tell kids apart in a narrow column.
    var shortName: String {
        let parts = name.split(separator: " ")
        guard let first = parts.first else { return name }
        guard parts.count > 1, let initial = parts.last?.first else { return String(first) }
        return "\(first) \(initial)."
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
