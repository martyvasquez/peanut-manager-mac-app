import Foundation

/// Who plays where in one inning.
public struct InningAssignment: Codable, Sendable, Hashable {
    public var positions: [Position: PlayerID]
    public var sitting: [PlayerID]

    public init(positions: [Position: PlayerID] = [:], sitting: [PlayerID] = []) {
        self.positions = positions
        self.sitting = sitting
    }

    public func slot(of player: PlayerID) -> Slot? {
        if let position = positions.first(where: { $0.value == player })?.key { return .field(position) }
        return sitting.contains(player) ? .bench : nil
    }

    /// Puts `player` in `slot`, removing them from wherever else they were this inning.
    /// Whoever held a taken position moves to the slot `player` came from (a true swap).
    public mutating func assign(_ player: PlayerID, to slot: Slot) {
        let previous = self.slot(of: player)
        guard previous != slot else { return }
        remove(player)
        switch slot {
        case .field(let position):
            if let displaced = positions[position] {
                positions[position] = nil
                switch previous {
                case .field(let old): positions[old] = displaced
                case .bench, .none: sitting.append(displaced)
                }
            }
            positions[position] = player
        case .bench:
            sitting.append(player)
        }
    }

    public mutating func remove(_ player: PlayerID) {
        for (position, id) in positions where id == player { positions[position] = nil }
        sitting.removeAll { $0 == player }
    }

    /// `a` and `b` trade places this inning, wherever each one is (a position, the bench, or nowhere yet).
    public mutating func swap(_ a: PlayerID, _ b: PlayerID) {
        guard a != b else { return }
        let slotA = slot(of: a), slotB = slot(of: b)
        remove(a); remove(b)
        place(a, in: slotB)
        place(b, in: slotA)
    }

    private mutating func place(_ player: PlayerID, in slot: Slot?) {
        switch slot {
        case .field(let position): positions[position] = player
        case .bench: sitting.append(player)
        case nil: break
        }
    }

    /// Positions nobody holds yet, in scorebook order.
    public var openPositions: [Position] { Position.allCases.filter { positions[$0] == nil } }

    /// Once every position is taken, anyone else who's available sits. Nothing changes while a position is open.
    public mutating func seatRest(available: [PlayerID]) {
        guard openPositions.isEmpty else { return }
        for id in available where slot(of: id) == nil { sitting.append(id) }
    }
}

/// A full game lineup: batting order plus a defensive assignment per inning (index 0 = inning 1).
public struct Lineup: Codable, Sendable, Hashable {
    public var battingOrder: [PlayerID]
    public var innings: [InningAssignment]

    public init(battingOrder: [PlayerID] = [], innings: [InningAssignment] = []) {
        self.battingOrder = battingOrder
        self.innings = innings
    }

    public func slot(of player: PlayerID, inning: Int) -> Slot? {
        guard innings.indices.contains(inning - 1) else { return nil }
        return innings[inning - 1].slot(of: player)
    }

    public mutating func assign(_ player: PlayerID, to slot: Slot, inning: Int) {
        guard innings.indices.contains(inning - 1) else { return }
        innings[inning - 1].assign(player, to: slot)
    }

    /// Grows or shrinks the defensive grid to `count` innings.
    public mutating func resize(innings count: Int) {
        if innings.count > count { innings.removeLast(innings.count - count) }
        while innings.count < count { innings.append(InningAssignment()) }
    }

    public var hasDefense: Bool { innings.contains { !$0.positions.isEmpty } }

    /// Where each inning goes when innings are inserted, removed or moved: old inning number → new (nil = removed).
    /// Used to carry locks and other per-inning notes along with the lineup.
    public typealias InningMap = (Int) -> Int?

    /// Adds an empty inning so it becomes inning `number` (1-based); later innings shift up.
    public mutating func insertInning(at number: Int) -> InningMap {
        let index = min(max(number - 1, 0), innings.count)
        innings.insert(InningAssignment(), at: index)
        return { $0 >= number ? $0 + 1 : $0 }
    }

    public mutating func removeInning(_ number: Int) -> InningMap {
        guard innings.indices.contains(number - 1) else { return { $0 } }
        innings.remove(at: number - 1)
        return { $0 == number ? nil : ($0 > number ? $0 - 1 : $0) }
    }

    /// Moves inning `from` so it becomes inning `to`; the ones between shift over.
    public mutating func moveInning(_ from: Int, to: Int) -> InningMap {
        guard innings.indices.contains(from - 1), innings.indices.contains(to - 1), from != to else { return { $0 } }
        innings.insert(innings.remove(at: from - 1), at: to - 1)
        return { inning in
            if inning == from { return to }
            if from < to, (from + 1...to).contains(inning) { return inning - 1 }
            if to < from, (to..<from).contains(inning) { return inning + 1 }
            return inning
        }
    }

    /// Every position is taken in every inning.
    public var isFullyPositioned: Bool { !innings.isEmpty && innings.allSatisfy { $0.openPositions.isEmpty } }

    /// A previous game's lineup as the start of a new one: kids who aren't coming drop out (leaving their spots open),
    /// innings past the new game's count are cut, missing innings start empty, and full innings seat everyone else.
    public func carriedOver(innings count: Int, present: Set<PlayerID>, available: (Int) -> [PlayerID]) -> Lineup {
        var copy = Lineup(battingOrder: battingOrder.filter(present.contains))
        guard hasDefense, count > 0 else { return copy }
        for inning in 1...count {
            let here = available(inning)
            var assignment = innings.indices.contains(inning - 1) ? innings[inning - 1] : InningAssignment()
            for (position, id) in assignment.positions where !here.contains(id) { assignment.positions[position] = nil }
            assignment.sitting.removeAll { !here.contains($0) }
            assignment.seatRest(available: here)
            copy.innings.append(assignment)
        }
        return copy
    }
}

/// A coach decision the AI must not change: `player` stays in `slot` during `inning`.
public struct Lock: Codable, Sendable, Hashable {
    public var inning: Int
    public var player: PlayerID
    public var slot: Slot

    public init(inning: Int, player: PlayerID, slot: Slot) {
        self.inning = inning
        self.player = player
        self.slot = slot
    }
}

/// Identifies one cell of the grid.
public struct CellKey: Codable, Sendable, Hashable {
    public var inning: Int
    public var player: PlayerID

    public init(inning: Int, player: PlayerID) {
        self.inning = inning
        self.player = player
    }
}

/// Who last decided a cell. Shown in the grid so the coach can always tell the AI's choices from the app's.
public enum Provenance: String, Codable, Sendable {
    case ai
    case aiRevised
    case appAdjusted
    case coach
}

/// A batting order while the coach builds it by hand: one spot per kid here, any of them still empty.
/// `Lineup.battingOrder` is these spots with the gaps closed.
public enum BattingSlots {
    /// The spots to show: the saved ones if they still match the order, or the order followed by empty spots.
    /// Kids who aren't here drop out, and there's one spot per kid who is.
    public static func resolve(_ saved: [PlayerID?]?, order: [PlayerID], present: [PlayerID]) -> [PlayerID?] {
        let here = Set(present)
        let placed = order.filter(here.contains)
        var slots: [PlayerID?]
        if let saved, saved.compactMap({ $0 }).filter(here.contains) == placed {
            slots = saved.map { $0.flatMap { here.contains($0) ? $0 : nil } }
        } else {
            slots = placed
        }
        while slots.count < present.count { slots.append(nil) }
        while slots.count > present.count, slots.last == .some(nil) { slots.removeLast() }
        return slots
    }

    /// Puts `player` in spot `index` (or the first empty one). A taken spot makes room: the kids there shift
    /// toward the nearest empty spot, below if there is one, else above. Moving within a full order is an insert.
    public static func place(_ player: PlayerID, at index: Int?, in slots: [PlayerID?]) -> [PlayerID?] {
        var s = slots
        if let from = s.firstIndex(of: player) { s[from] = nil }
        guard let i = index ?? s.firstIndex(of: nil), s.indices.contains(i) else { return slots }
        if s[i] == nil {
            s[i] = player
        } else if let k = s[(i + 1)...].firstIndex(of: nil) {
            for m in stride(from: k, to: i, by: -1) { s[m] = s[m - 1] }
            s[i] = player
        } else if let k = s[..<i].lastIndex(of: nil) {
            for m in k..<i { s[m] = s[m + 1] }
            s[i] = player
        } else {
            return slots
        }
        return s
    }
}
