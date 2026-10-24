import SwiftUI
import LineupKit

/// The game on a phone: the whole grid on one screen, and below it either the selected spot's positions (the tray)
/// or one inning on the field. Tap a spot to pick its position; with a spot picked, tap another spot in the same
/// inning to swap the two. Tap an inning's number to see it on the field.
struct PhoneGameView: View {
    @State private var model = SpikeModel.sample()
    @State private var selected: CellKey?
    @State private var fieldInning = 1

    private let panelHeight: CGFloat = 246
    private let headerHeight: CGFloat = 30

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let rows = model.rows
                // Rows sized so the whole game fits above the panel; small phones scroll.
                let fit = (geo.size.height - panelHeight - headerHeight - 8) / CGFloat(max(rows.count, 1))
                let rowHeight = min(max(fit, 34), 48)
                VStack(spacing: 0) {
                    ScrollView {
                        PhoneGrid(model: model, selected: $selected, fieldInning: $fieldInning,
                                  width: geo.size.width - 24, rowHeight: rowHeight, headerHeight: headerHeight)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    panel
                        .frame(height: panelHeight)
                }
            }
            .navigationTitle(model.opponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { withAnimation(.snappy) { model.undo() } }
                        .disabled(!model.canUndo)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Clear Positions", systemImage: "eraser") {
                            withAnimation(.snappy) { model.clearPositions() }
                            selected = nil
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.swaps)
        .sensoryFeedback(.selection, trigger: selected)
        .onAppear(perform: debugSetup)
    }

    @ViewBuilder
    private var panel: some View {
        Group {
            if let key = selected {
                PositionTray(model: model, key: key, selected: $selected)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                InningPanel(model: model, inning: $fieldInning)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background.secondary, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .ignoresSafeArea(edges: .bottom)
        .animation(.snappy(duration: 0.25), value: selected == nil)
    }

    /// `-PMSelect 3:2` opens the tray on inning 3, row 2 (from 0), for screenshots.
    private func debugSetup() {
        guard let spec = UserDefaults.standard.string(forKey: "PMSelect") else { return }
        let parts = spec.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let player = model.rows[safe: parts[1]] else { return }
        selected = CellKey(inning: parts[0], player: player.id)
    }
}

// MARK: - Grid

struct PhoneGrid: View {
    let model: SpikeModel
    @Binding var selected: CellKey?
    @Binding var fieldInning: Int
    let width: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat

    private var cellWidth: CGFloat { min(max((width - 96) / CGFloat(model.innings), 36), 56) }
    private var nameWidth: CGFloat { width - cellWidth * CGFloat(model.innings) }

    var body: some View {
        let rows = model.rows
        let problems = problemCells
        let selectedSlot = selected.flatMap(model.slot)
        VStack(spacing: 0) {
            header
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, player in
                HStack(spacing: 0) {
                    nameCell(player, order: index + 1)
                    ForEach(1...model.innings, id: \.self) { inning in
                        cell(CellKey(inning: inning, player: player.id), problem: problems.contains(CellKey(inning: inning, player: player.id)), selectedSlot: selectedSlot)
                    }
                }
                .frame(height: rowHeight)
                .overlay(alignment: .bottom) { Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: nameWidth)
            ForEach(1...model.innings, id: \.self) { inning in
                let shown = selected?.inning == inning || (selected == nil && fieldInning == inning)
                Text("\(inning)")
                    .font(.subheadline.weight(shown ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(shown ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: cellWidth, height: headerHeight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selected = nil
                        fieldInning = inning
                    }
            }
        }
    }

    private func nameCell(_ player: PlayerSnapshot, order: Int) -> some View {
        let breaks = !ruleBreaks(player.id).isEmpty
        let isSelectedRow = selected?.player == player.id
        return HStack(spacing: 6) {
            Text(model.lineup.battingOrder.contains(player.id) ? "\(order)" : "")
                .font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)
            Text(player.shortName)
                .font(.subheadline.weight(isSelectedRow ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(breaks ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
        }
        .frame(width: nameWidth, alignment: .leading)
    }

    private func cell(_ key: CellKey, problem: Bool, selectedSlot: Slot?) -> some View {
        let slot = model.slot(key)
        let isSelected = selected == key
        let available = model.context.availability(of: key.player).isAvailable(inning: key.inning)
        // The picked kid's position, lit in every inning, so you can follow who plays it.
        let lit = !isSelected && slot != nil && slot == selectedSlot && { if case .field = slot { true } else { false } }()
        // With a placed spot picked, the placed spots it can't swap with in its inning fade.
        let sameInning = selected.map { $0.inning == key.inning && !isSelected } ?? false
        let swappable = sameInning && selectedSlot != nil && slot != nil && model.canSwap(selected!.player, key.player, inning: key.inning)
        let faded = sameInning && selectedSlot != nil && slot != nil && !swappable
        let locked = model.isLocked(key)

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor)
                      : problem ? AnyShapeStyle(Color.red.opacity(0.14))
                      : lit ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                      : available ? AnyShapeStyle(.quaternary.opacity(0.5))
                      : AnyShapeStyle(Color.clear))
            Text(label(slot, available: available))
                .font(slot == .bench ? .caption.weight(.semibold) : .subheadline.weight(slot == .field(.p) ? .bold : .medium))
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
        .padding(2.5)
        .frame(width: cellWidth, height: rowHeight)
        .opacity(faded ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if available { tap(key) } }
        .contextMenu {
            if available, slot != nil {
                Button(locked ? "Unlock" : "Lock", systemImage: locked ? "lock.open" : "lock") { model.toggleLock(key) }
            }
            if available, slot != .bench {
                Button("Sit", systemImage: "chair") { withAnimation(.snappy) { model.assign(key.player, to: .bench, inning: key.inning) } }
            }
        }
        .animation(.snappy(duration: 0.2), value: slot)
    }

    /// First tap picks a spot. With a placed spot picked, a tap on another placed spot in its inning swaps them;
    /// anything else picks the new spot, and a second tap on the same spot lets go.
    private func tap(_ key: CellKey) {
        guard let current = selected else { selected = key; return }
        if current == key { selected = nil; return }
        if current.inning == key.inning, model.slot(current) != nil, model.slot(key) != nil,
           model.canSwap(current.player, key.player, inning: key.inning) {
            withAnimation(.snappy) { model.swap(current.player, key.player, inning: key.inning) }
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

    private func ruleBreaks(_ player: PlayerID) -> [Finding] {
        model.findings.filter { $0.severity == .violation && $0.player == player && $0.inning == nil }
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
}

// MARK: - Tray

/// The picked spot's choices, laid out like the field: open, taken (tap to swap), theirs now, can't play.
struct PositionTray: View {
    let model: SpikeModel
    let key: CellKey
    @Binding var selected: CellKey?

    var body: some View {
        let player = model.context.player(key.player)
        let assignment = model.lineup.innings[key.inning - 1]
        let current = assignment.slot(of: key.player)
        let locked = model.isLocked(key)
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                Text(player?.shortName ?? "").font(.headline)
                Text("Inning \(key.inning)").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if current != nil {
                    Button(locked ? "Unlock" : "Lock", systemImage: locked ? "lock.fill" : "lock.open") { model.toggleLock(key) }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(locked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: 40, height: 36)
                }
                Button("Previous Inning", systemImage: "chevron.left") { step(-1) }
                    .labelStyle(.iconOnly).frame(width: 40, height: 36)
                    .disabled(key.inning <= 1)
                Button("Next Inning", systemImage: "chevron.right") { step(1) }
                    .labelStyle(.iconOnly).frame(width: 40, height: 36)
                    .disabled(key.inning >= model.innings)
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
        let taken = holder != nil
        return Button { pick(.field(position)) } label: {
            VStack(spacing: 1) {
                HStack(spacing: 2) {
                    if fit >= .good { Image(systemName: "star.fill").font(.system(size: 9)) }
                    Text(position.label).strikethrough(!fit.isEligible)
                }
                .font(.headline)
                if let holder { Text(holder.firstName).font(.caption).foregroundStyle(mine ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary)).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(mine ? AnyShapeStyle(Color.white)
                             : !fit.isEligible ? AnyShapeStyle(.quaternary)
                             : AnyShapeStyle(.primary))
            .background(mine ? AnyShapeStyle(Color.accentColor)
                        : !fit.isEligible ? AnyShapeStyle(Color.clear)
                        : AnyShapeStyle(Color.primary.opacity(taken ? 0.07 : 0.14)),
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
        withAnimation(.snappy) { model.assign(key.player, to: slot, inning: key.inning) }
        let rows = model.rows.map(\.id)
        let unplaced = Set(model.unplaced(inning: key.inning).map(\.id))
        let start = rows.firstIndex(of: key.player) ?? 0
        let next = (rows[(start + 1)...] + rows[..<start]).first(where: unplaced.contains)
        selected = next.map { CellKey(inning: key.inning, player: $0) }
    }

    private func step(_ delta: Int) {
        selected = CellKey(inning: key.inning + delta, player: key.player)
    }
}

// MARK: - Inning on the field

/// One inning as the coach pictures it, with the rule status above it. Swipe or use the arrows to step innings.
struct InningPanel: View {
    let model: SpikeModel
    @Binding var inning: Int

    private let scale: CGFloat = 0.64

    var body: some View {
        let assignment = model.lineup.innings[inning - 1]
        let sitting = assignment.sitting.compactMap { model.context.player($0) }
        let unplaced = model.unplaced(inning: inning)
        let violations = model.findings.filter { $0.severity == .violation }
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button("Previous Inning", systemImage: "chevron.left") { inning -= 1 }
                    .labelStyle(.iconOnly).frame(width: 36, height: 32).disabled(inning <= 1)
                Text("Inning \(inning)").font(.headline).monospacedDigit()
                Button("Next Inning", systemImage: "chevron.right") { inning += 1 }
                    .labelStyle(.iconOnly).frame(width: 36, height: 32).disabled(inning >= model.innings)
                Spacer()
                status(violations)
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))

            ZStack(alignment: .topLeading) {
                FieldDrawing(scale: scale)
                ForEach(Position.allCases, id: \.self) { position in
                    let p = FieldGeometry.point(FieldGeometry.fielder[position]!)
                    let holder = assignment.positions[position].flatMap { model.context.player($0) }
                    spot(position, holder: holder)
                        .position(x: p.x * scale, y: p.y * scale)
                }
            }
            .frame(width: FieldGeometry.size.width * scale, height: FieldGeometry.size.height * scale)
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Text(unplaced.isEmpty ? "Sitting" : "Not placed")
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
            if value.translation.width < -40, inning < model.innings { inning += 1 }
            if value.translation.width > 40, inning > 1 { inning -= 1 }
        })
        .animation(.snappy, value: inning)
    }

    @ViewBuilder
    private func status(_ violations: [Finding]) -> some View {
        if !violations.isEmpty {
            Label("\(violations.count) rule \(violations.count == 1 ? "problem" : "problems")", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(.red)
        } else if model.isFilled {
            Label("Follows your rules", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(.green)
        } else {
            Text("\(model.openSpots) open").font(.subheadline).foregroundStyle(.secondary)
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
