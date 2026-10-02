import Foundation

/// The nine defensive positions, in scorebook order.
public enum Position: String, CaseIterable, Codable, Sendable, Hashable, CodingKeyRepresentable, Comparable {
    case p = "P"
    case c = "C"
    case first = "1B"
    case second = "2B"
    case third = "3B"
    case ss = "SS"
    case lf = "LF"
    case cf = "CF"
    case rf = "RF"

    public var label: String { rawValue }

    public var isInfield: Bool {
        switch self {
        case .p, .c, .first, .second, .third, .ss: true
        case .lf, .cf, .rf: false
        }
    }

    public var isOutfield: Bool { !isInfield }

    /// Scorebook number (P = 1 … RF = 9).
    public var number: Int { Position.allCases.firstIndex(of: self)! + 1 }

    public static func < (lhs: Position, rhs: Position) -> Bool { lhs.number < rhs.number }

    /// Parses labels the AI or a coach might type: "SS", "ss", "1b", "6".
    public init?(label: String) {
        let s = label.trimmingCharacters(in: .whitespaces).uppercased()
        if let p = Position(rawValue: s) { self = p; return }
        if let n = Int(s), (1...9).contains(n) { self = Position.allCases[n - 1]; return }
        return nil
    }
}

/// How well a player fits a position. Replaces v1's eligibility flags + ranked strengths.
public enum Fit: Int, CaseIterable, Codable, Sendable, Comparable {
    case cant = 0
    case can = 1
    case good = 2
    case primary = 3

    public var label: String {
        switch self {
        case .cant: "Can't"
        case .can: "Can"
        case .good: "Good"
        case .primary: "Primary"
        }
    }

    public var isEligible: Bool { self != .cant }

    public static func < (lhs: Fit, rhs: Fit) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A player's fit at every position.
public struct PositionProfile: Codable, Sendable, Hashable {
    public var fits: [Position: Fit]

    public init(fits: [Position: Fit] = [:]) {
        self.fits = fits
    }

    /// New players can play anywhere except pitcher and catcher, which coaches opt into
    /// deliberately (as v1's eligibility flags required).
    public static let `default` = PositionProfile(fits: [.p: .cant, .c: .cant])

    public subscript(position: Position) -> Fit {
        get { fits[position] ?? .can }
        set { fits[position] = newValue }
    }

    public func canPlay(_ position: Position) -> Bool { self[position].isEligible }

    /// Eligible positions, strongest first (ties in scorebook order).
    public var strengths: [Position] {
        Position.allCases
            .filter { canPlay($0) }
            .sorted { (self[$0], $1) > (self[$1], $0) }
    }

    public var ineligible: [Position] { Position.allCases.filter { !canPlay($0) } }
}

/// Where a player is during one inning.
public enum Slot: Hashable, Codable, Sendable, CustomStringConvertible {
    case field(Position)
    case bench

    public var description: String {
        switch self {
        case .field(let p): p.label
        case .bench: "SIT"
        }
    }
}
