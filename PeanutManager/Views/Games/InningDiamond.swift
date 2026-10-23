import SwiftUI
import AppKit
import LineupKit

/// One inning on the field, the way a coach pictures it. Drag a kid onto another to trade places, onto an open
/// position to put them there, or onto Sitting to sit them. The arrows step through the innings.
/// A kid at one of their best positions (the orange ones on the roster) gets an orange ring and ★; while dragging,
/// the ring moves to the spots that are best for the kid being dragged.
struct InningDiamond: View {
    let model: GameModel
    @State var inning: Int
    let undoManager: UndoManager?
    @State private var dragging: PlayerID?
    @State private var target: Target?

    enum Target: Hashable { case player(PlayerID), position(Position), bench }

    private static let scale: CGFloat = 1.45

    var body: some View {
        let assignment = model.lineup.innings[safe: inning - 1] ?? InningAssignment()
        let ctx = model.context
        let unplaced = ctx.availablePlayers(inning: inning).filter { assignment.slot(of: $0.id) == nil }
        let sitting = assignment.sitting.compactMap { ctx.player($0) }
        let s = Self.scale

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Button { inning -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(inning <= 1)
                Text("Inning \(inning)").font(.headline).monospacedDigit()
                Button { inning += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(inning >= model.game.innings)
                Spacer()
            }
            .buttonStyle(.borderless)

            ZStack(alignment: .topLeading) {
                FieldDrawing(scale: s)
                ForEach(Position.allCases, id: \.self) { position in
                    let p = FieldGeometry.point(FieldGeometry.fielder[position]!)
                    spot(position, holder: assignment.positions[position].flatMap { ctx.player($0) })
                        .position(x: p.x * s, y: p.y * s)
                }
            }
            .frame(width: FieldGeometry.size.width * s, height: FieldGeometry.size.height * s)

            group("Sitting", sitting, dropsTo: .bench)
            if !unplaced.isEmpty { group("Not Placed", unplaced, dropsTo: nil) }
        }
        .padding(18)
        .animation(.snappy, value: assignment)
        // A drag dropped outside any target never reports back; the next plain mouse move ends it.
        .onContinuousHover { _ in
            if dragging != nil && NSEvent.pressedMouseButtons == 0 { dragging = nil; target = nil }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func spot(_ position: Position, holder: PlayerSnapshot?) -> some View {
        if let holder {
            chip(holder, at: position)
        } else {
            let lit = target == .position(position) && dragging.map { canPlace($0, at: position) } == true
            let hint = dragging.map { isBest($0, at: position) } == true
            Text(position.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(lit || hint ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 44, height: 44)
                .background(lit ? Color.accentColor.opacity(0.15) : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(lit || hint ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: hint ? 1.5 : 1, dash: hint ? [] : [3, 2])))
                .contentShape(Circle())
                .onDrop(of: [.plainText], isTargeted: targeted(.position(position))) { _ in drop(on: .position(position)) }
                .help("\(position.label) is open")
        }
    }

    /// A kid, by first name, at `position` on the field (nil on the bench or not placed).
    private func chip(_ player: PlayerSnapshot, at position: Position?) -> some View {
        let lit = target == .player(player.id) && dragging.map { $0 != player.id && model.canSwap($0, player.id, inning: inning) } == true
        let best = position.map { isBest(player.id, at: $0) } == true
        // While dragging, ring the spots that are best for the dragged kid instead.
        let ringed = if let dragging, dragging != player.id {
            position.map { isBest(dragging, at: $0) && model.canSwap(dragging, player.id, inning: inning) } == true
        } else {
            dragging == nil && best
        }
        return VStack(spacing: 0) {
            if let position {
                Text(position.label).font(.caption2.weight(.semibold)).foregroundStyle(lit ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            HStack(spacing: 3) {
                if best { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(lit ? Color.white : Color.accentColor) }
                Text(Self.firstName(player)).font(.callout.weight(.medium)).lineLimit(1)
                    .foregroundStyle(lit ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, position == nil ? 6 : 4)
        .frame(minWidth: 64)
        .background(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: Capsule())
        .overlay(Capsule().strokeBorder(ringed ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: ringed ? 1.5 : 0.5))
        .help(best ? "\(player.name) · one of their best positions" : player.name)
        .scaleEffect(lit ? 1.08 : 1)
        .opacity(dragging == player.id ? 0.35 : 1)
        .contentShape(Capsule())
        .onDrag {
            dragging = player.id
            return NSItemProvider(object: player.id.uuidString as NSString)
        } preview: {
            Text(Self.firstName(player)).font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .onDrop(of: [.plainText], isTargeted: targeted(.player(player.id))) { _ in drop(on: .player(player.id)) }
        .animation(.snappy(duration: 0.18), value: lit)
    }

    /// Sitting (a drop target: drop a kid here to sit them) or Not Placed (just a source).
    private func group(_ title: String, _ players: [PlayerSnapshot], dropsTo: Target?) -> some View {
        let lit = dropsTo != nil && target == dropsTo && dragging != nil
        return HStack(alignment: .center, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            if players.isEmpty {
                Text("Nobody").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(players) { chip($0, at: nil) }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(minHeight: 44)
        .background(lit ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .modifier(DropIf(enabled: dropsTo != nil, isTargeted: targeted(dropsTo ?? .bench)) { drop(on: .bench) })
    }

    // MARK: Drag and drop

    private func targeted(_ spot: Target) -> Binding<Bool> {
        Binding(get: { target == spot }, set: { target = $0 ? spot : (target == spot ? nil : target) })
    }

    /// "Best" on the roster (Good or Primary).
    private func isBest(_ player: PlayerID, at position: Position) -> Bool {
        (model.context.player(player)?.profile[position] ?? .cant) >= .good
    }

    private func canPlace(_ player: PlayerID, at position: Position) -> Bool {
        model.context.player(player)?.profile.canPlay(position) ?? false
    }

    private func drop(on spot: Target) -> Bool {
        defer { dragging = nil; target = nil }
        guard let dragging else { return false }
        switch spot {
        case .player(let other):
            guard model.canSwap(dragging, other, inning: inning) else { return false }
            model.swap(dragging, other, inning: inning, undoManager: undoManager)
        case .position(let position):
            guard canPlace(dragging, at: position) else { return false }
            model.assign(dragging, to: .field(position), inning: inning, undoManager: undoManager)
        case .bench:
            guard model.lineup.slot(of: dragging, inning: inning) != .bench else { return false }
            model.assign(dragging, to: .bench, inning: inning, undoManager: undoManager)
        }
        LineupGridView.snap()
        return true
    }

    static func firstName(_ player: PlayerSnapshot) -> String {
        player.name.components(separatedBy: " ").first ?? player.name
    }
}

/// Makes a view a drop target only when `enabled`.
private struct DropIf: ViewModifier {
    let enabled: Bool
    let isTargeted: Binding<Bool>
    let perform: () -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.plainText], isTargeted: isTargeted) { _ in perform() }
        } else {
            content
        }
    }
}
