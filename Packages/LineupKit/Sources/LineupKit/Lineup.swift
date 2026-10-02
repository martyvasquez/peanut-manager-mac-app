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
