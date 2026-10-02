import Foundation

/// The last-resort safety net. Runs only when the AI still can't produce a valid lineup after revising.
/// It makes the smallest changes it can to the AI's lineup, never builds one from scratch, and reports
/// every cell it touched so the coach can see exactly what the app changed.
public enum Repair {
    public static func battingOrder(_ order: [PlayerID], context: GameContext) -> [PlayerID] {
        var seen = Set<PlayerID>()
        var result = order.filter { id in
            context.player(id) != nil && context.availability(of: id).present && seen.insert(id).inserted
        }
        for player in context.presentPlayers where !seen.contains(player.id) {
            result.append(player.id)
        }
        return result
    }

    public static func defense(_ original: Lineup, context: GameContext) -> (lineup: Lineup, adjusted: Set<CellKey>) {
        var lineup = original
        lineup.resize(innings: context.innings)
        var adjusted = Set<CellKey>()
        var pulled = Set<PlayerID>()
        var previousPitcher: PlayerID?
        var sitsSoFar: [PlayerID: Int] = [:]

        for index in lineup.innings.indices {
            let inning = index + 1
            let before = lineup.innings[index]
            var a = before
            let available = context.availablePlayers(inning: inning)
            let availableIDs = Set(available.map(\.id))
            let locks = context.locks.filter { $0.inning == inning && availableIDs.contains($0.player) }
            let locked = Set(locks.map(\.player))

            // 1. Drop players who are unknown, unavailable, or listed twice (first listing wins).
            var seen = Set<PlayerID>()
            for position in Position.allCases {
                guard let id = a.positions[position] else { continue }
                if !availableIDs.contains(id) || !seen.insert(id).inserted { a.positions[position] = nil }
            }
            a.sitting = a.sitting.filter { availableIDs.contains($0) && seen.insert($0).inserted }

            // 2. Coach locks win.
            for lock in locks { a.assign(lock.player, to: lock.slot) }

            // 3. Everyone available is somewhere.
            for player in available where a.slot(of: player.id) == nil { a.sitting.append(player.id) }

            // 4. Bench anyone at a position they can't play, or a pulled pitcher back on the mound.
            for position in Position.allCases {
                guard let id = a.positions[position], !locked.contains(id), let player = context.player(id) else { continue }
                let reentry = position == .p && pulled.contains(id)
                if !player.profile.canPlay(position) || reentry {
                    a.positions[position] = nil
                    a.sitting.append(id)
                }
            }

            // 5. Fill empty positions. Prefer the player the AI meant to be here, then anyone the AI had
            //    fielding (displaced by a fix above), then the best fit, then whoever has sat most.
            func canTake(_ id: PlayerID, _ position: Position) -> Bool {
                guard let player = context.player(id), player.profile.canPlay(position) else { return false }
                return !(position == .p && pulled.contains(id))
            }
            func rank(_ id: PlayerID, _ position: Position) -> (Int, Int, Fit, Int) {
                let intended = before.positions[position] == id ? 1 : 0
                let displaced = before.slot(of: id) != .bench ? 1 : 0
                return (intended, displaced, context.player(id)!.profile[position], sitsSoFar[id, default: 0])
            }
            func bestBench(for position: Position) -> PlayerID? {
                a.sitting
                    .filter { !locked.contains($0) && canTake($0, position) }
                    .max { rank($0, position) < rank($1, position) }
            }
            for position in [Position.p, .c] + Position.allCases.filter({ $0 != .p && $0 != .c })
            where a.positions[position] == nil {
                if let id = bestBench(for: position) {
                    a.assign(id, to: .field(position))
                    continue
                }
                // One-step chain: move an eligible fielder here, backfill their spot from the bench.
                outer: for other in Position.allCases where other != position {
                    guard let fielder = a.positions[other], !locked.contains(fielder), canTake(fielder, position) else { continue }
                    for bench in a.sitting where !locked.contains(bench) && canTake(bench, other) {
                        a.positions[other] = nil
                        a.positions[position] = fielder
                        a.sitting.removeAll { $0 == bench }
                        a.positions[other] = bench
                        break outer
                    }
                }
            }

            lineup.innings[index] = a
            for player in available where before.slot(of: player.id) != a.slot(of: player.id) {
                adjusted.insert(CellKey(inning: inning, player: player.id))
            }
            for id in a.sitting { sitsSoFar[id, default: 0] += 1 }
            let pitcher = a.positions[.p]
            if let previousPitcher, previousPitcher != pitcher { pulled.insert(previousPitcher) }
            previousPitcher = pitcher
        }
        return (lineup, adjusted)
    }
}
