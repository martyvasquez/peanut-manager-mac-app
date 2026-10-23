import SwiftUI
import LineupKit

/// One inning on the field, the way a coach pictures it. Drag a kid onto another to trade places, onto an open
/// position to put them there, or onto Sitting to sit them. The arrows step through the innings.
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
    }

    // MARK: Pieces

    @ViewBuilder
    private func spot(_ position: Position, holder: PlayerSnapshot?) -> some View {
        if let holder {
            chip(holder, caption: position.label)
        } else {
            let lit = target == .position(position) && dragging.map { canPlace($0, at: position) } == true
            Text(position.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 44, height: 44)
                .background(lit ? Color.accentColor.opacity(0.15) : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(lit ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Circle())
                .onDrop(of: [.plainText], isTargeted: targeted(.position(position))) { _ in drop(on: .position(position)) }
                .help("\(position.label) is open")
        }
    }

    /// A kid, by first name. `caption` is their position on the field.
    private func chip(_ player: PlayerSnapshot, caption: String?) -> some View {
        let lit = target == .player(player.id) && dragging.map { $0 != player.id && model.canSwap($0, player.id, inning: inning) } == true
        return VStack(spacing: 0) {
            if let caption {
                Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(lit ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            Text(Self.firstName(player)).font(.callout.weight(.medium)).lineLimit(1)
                .foregroundStyle(lit ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, caption == nil ? 6 : 4)
        .frame(minWidth: 64)
        .background(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
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
        .help(player.name)
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
            ForEach(players) { chip($0, caption: nil) }
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
