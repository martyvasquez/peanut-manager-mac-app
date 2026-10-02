import Foundation

/// Short, stable IDs ("P1", "P2", …) used in prompts instead of UUIDs.
/// Shorter IDs are cheaper and easier for the model to copy exactly.
public struct PromptIDs: Sendable {
    public let byPlayer: [PlayerID: String]
    public let byToken: [String: PlayerID]

    public init(players: [PlayerSnapshot]) {
        var byPlayer: [PlayerID: String] = [:]
        var byToken: [String: PlayerID] = [:]
        for (index, player) in players.enumerated() {
            let token = "P\(index + 1)"
            byPlayer[player.id] = token
            byToken[token] = player.id
        }
        self.byPlayer = byPlayer
        self.byToken = byToken
    }

    public func token(_ id: PlayerID) -> String { byPlayer[id] ?? "?" }

    /// Replaces any stray IDs ("P7") in the model's prose with the player's name.
    public func humanize(_ text: String, players: [PlayerSnapshot]) -> String {
        text.replacing(/\bP(\d+)\b/) { match in
            guard let id = byToken["P\(match.1)"], let player = players.first(where: { $0.id == id }) else { return String(match.0) }
            return player.name.components(separatedBy: " ").first ?? player.name
        }
    }
}

/// Prompts ported from v1 (`lib/ai/claude-client.ts` and `lib/ai/prompt-builder.ts`), which graded a B in real use.
/// Deliberate v2 changes, each fixing an audited v1 gap (see docs/v2-plan.md, Appendix B):
/// - unrated skills say "unrated" instead of silently becoming 3
/// - the player's own coach notes are included, not just the game-specific note
/// - eligibility and strengths come from the single position profile
/// - late arrivals / early departures are stated
/// - short player IDs, and the AI's self-reported rules_check is no longer trusted (code validates)
public enum Prompts {
    public static let battingSystem = """
    You are a youth baseball lineup optimizer specializing in batting order construction.

    INPUTS YOU WILL RECEIVE:
    - Available players with their ratings and stats
    - Team rules that may affect batting order
    - Coach preferences and notes

    BATTING ORDER PRINCIPLES:
    1. Lead-off (1st): Best on-base skills, speed, discipline
    2. Second: Good contact, can move runners, some speed
    3. Third: Best overall hitter, high average and power
    4. Clean-up (4th): Most power, drives in runs
    5. Fifth: Strong hitter, secondary power
    6. Sixth-onwards: Decreasing offensive ability, but still capable

    OUTPUT FORMAT:
    Return valid JSON only. No markdown, no explanation outside the JSON structure.
    Use each player's ID exactly as given (for example "P3"). Include every available player exactly once.
    In reasoning and rationale, refer to players by first name, never by ID. Keep each reasoning to one short sentence and the rationale to 2-3 sentences.
    """

    public static let defensiveSystem = """
    You are a youth baseball lineup optimizer specializing in defensive positioning.

    INPUTS YOU WILL RECEIVE:
    - Batting order (already determined)
    - Player position strengths and eligibility
    - Locked positions (DO NOT CHANGE THESE)
    - Team rules for defensive rotation
    - Coach preferences

    CRITICAL REQUIREMENTS:
    1. EVERY inning MUST have ALL 9 field positions filled: P, C, 1B, 2B, 3B, SS, LF, CF, RF
    2. NO position can be left empty or null - every position MUST have a player assigned
    3. Extra players beyond the 9 fielders go in the "sit" array
    4. LOCKED POSITIONS must not be changed - they are coach decisions
    5. PITCHER RULE: Once a player stops pitching, they CANNOT return to pitch later in the game. If a player pitches innings 1-2, they cannot pitch again in innings 3+. This is a fundamental baseball rule.
    6. A player can only be in one place per inning, and only plays innings they are available for.
    7. Never put a player at a position listed under "Cannot play".

    DEFENSIVE PRINCIPLES:
    1. Premium positions (P, C, SS, 1B) require eligibility
    2. Use player position strengths to optimize assignments
    3. Rotate players for development (avoid same position all game)
    4. Balance sitting time across all players
    5. Consider stamina - don't overwork young players

    OUTPUT FORMAT:
    Return valid JSON only. No markdown, no explanation outside the JSON structure.
    Use each player's ID exactly as given (for example "P3").
    In reasoning, rationale and warnings, refer to players by first name, never by ID. Keep each inning's reasoning to one short sentence, the rationale to 2-3 sentences, and include only warnings the coach must act on.
    IMPORTANT: Every inning object MUST have all 9 positions (P, C, 1B, 2B, 3B, SS, LF, CF, RF) with valid player assignments. No nulls or missing positions allowed.
    """

    static let priorityDirectives: [GamePriority: String] = [
        .win: "PRIMARY DIRECTIVE: Winning is the top priority. Always recommend the lineup, plays, and substitutions that maximize the chance of winning, regardless of player development considerations. Prioritize experienced players and proven strategies over giving less experienced players opportunities.",
        .winLeaning: "PRIMARY DIRECTIVE: Winning takes priority over player development. Favor decisions that increase win probability, but when the game situation allows (comfortable lead, low-stakes moments), you may suggest development opportunities. Never sacrifice a likely win for development purposes.",
        .balanced: "PRIMARY DIRECTIVE: Winning and player development carry equal weight. Seek decisions that advance both goals when possible. In close games, lean toward winning; in comfortable situations, lean toward development. Explicitly acknowledge tradeoffs when they exist.",
        .devLeaning: "PRIMARY DIRECTIVE: Player development takes priority over winning. Favor decisions that maximize learning and growth opportunities, but do not completely abandon competitive play. In critical moments, winning considerations may factor in, but default to development-focused choices.",
        .develop: "PRIMARY DIRECTIVE: Player development is the top priority. Always recommend decisions that maximize player growth, learning, and experience—even at the cost of winning. Rotate players, try new strategies, and give all players meaningful opportunities regardless of game situation.",
    ]

    static let weightingDirectives: [DataWeighting: String] = [
        .gcOnly: "DATA DIRECTIVE: Base all player evaluations solely on the GameChanger statistics provided. Ignore coach ratings.",
        .gcHeavy: "DATA DIRECTIVE: Prioritize GameChanger data (75%) over coach ratings (25%). Use stats as primary evidence, coach ratings as secondary input.",
        .equal: "DATA DIRECTIVE: Weight GameChanger data and coach ratings equally. Consider both objective stats and subjective coach observations.",
        .coachHeavy: "DATA DIRECTIVE: Prioritize coach ratings (75%) over GameChanger data (25%). Use coach observations as primary evidence, stats as secondary input.",
        .coachOnly: "DATA DIRECTIVE: Base all player evaluations solely on the coach ratings provided. Ignore GameChanger statistics.",
    ]

    // MARK: - Batting order (phase 1)

    public static func battingOrder(_ context: GameContext, ids: PromptIDs, currentOrder: [PlayerID]? = nil, feedback: String? = nil) -> String {
        let players = context.presentPlayers.map { battingPlayerText($0, context: context, ids: ids) }.joined(separator: "\n")
        var regenerate = ""
        if let feedback, !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let currentOrder, !currentOrder.isEmpty {
                regenerate += "\n\nCURRENT BATTING ORDER (for context - the coach wants adjustments):\n"
                    + currentOrder.enumerated().map { "\($0.offset + 1). \(context.name($0.element)) (\(ids.token($0.element)))" }.joined(separator: "\n")
            }
            regenerate += "\n\nCOACH FEEDBACK (IMPORTANT - This is what the coach wants changed):\n\(feedback)"
        }
        return """
        \(header(context))
        You will be coming up with the batting order.

        Here are the rules listed in order of priority that you must follow:
        \(rulesText(context.activeRules, numberingFrom: 1, emptyText: "(No rules defined - use your expertise as a youth baseball coach)"))

        Here are the available players:
        \(players)
        \(footer(context))\(regenerate)

        Return JSON only:

        {
          "batting_order": [
            {"order": 1, "player_id": "P1", "reasoning": "string"}
          ],
          "rationale": "Brief overall explanation of the batting order strategy"
        }
        """
    }

    // MARK: - Defense (phase 2)

    public static func defense(
        _ context: GameContext,
        battingOrder: [PlayerID],
        ids: PromptIDs,
        currentLineup: Lineup? = nil,
        feedback: String? = nil
    ) -> String {
        let order = battingOrder.enumerated()
            .map { "\($0.offset + 1). \(context.name($0.element)) (ID: \(ids.token($0.element)))" }
            .joined(separator: "\n")
        let players = context.presentPlayers.map { defensivePlayerText($0, context: context, ids: ids) }.joined(separator: "\n")
        let rules = "1. All locked positions must be maintained (see locked positions below)" +
            (context.activeRules.isEmpty ? "" : "\n" + rulesText(context.activeRules, numberingFrom: 2, emptyText: ""))

        var regenerate = ""
        if let feedback, !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let currentLineup, currentLineup.hasDefense {
                regenerate += "\n\nCURRENT LINEUP (for context - the coach wants adjustments):\n" + describe(currentLineup, context: context, ids: ids)
            }
            regenerate += "\n\nCOACH FEEDBACK (IMPORTANT - This is what the coach wants changed):\n\(feedback)"
        }

        return """
        \(header(context))
        You will be coming up with defense and positions for \(context.innings) innings.

        CRITICAL: You MUST assign a player to EVERY position (P, C, 1B, 2B, 3B, SS, LF, CF, RF) for EVERY inning. No position can be left empty. Players who are not fielding go in the "sit" array.

        PITCHER RULE: Once a player is removed from pitching, they CANNOT return to pitch later in the game. For example, if a player pitches innings 1-2 and then plays another position in inning 3, they cannot pitch again in innings 4, 5, 6, etc. Plan pitcher usage carefully.

        Here are the rules listed in order of priority that you must follow:
        \(rules)

        Batting Order (already determined):
        \(order)

        Locked Positions (DO NOT CHANGE):
        \(lockedText(context, ids: ids))

        Here are the available players:
        \(players)
        \(footer(context))\(regenerate)

        Return JSON only:

        {
          "defense": [
            {
              "inning": 1,
              "P": "P1", "C": "P2", "1B": "P3", "2B": "P4", "3B": "P5", "SS": "P6", "LF": "P7", "CF": "P8", "RF": "P9",
              "sit": ["P10"],
              "reasoning": "Brief explanation for this inning's assignments"
            }
          ],
          "rules_check": [
            {"rule": "string", "satisfied": true, "details": "string"}
          ],
          "warnings": ["string"],
          "rationale": "Brief overall explanation of the defensive strategy"
        }
        """
    }

    // MARK: - Revise

    /// Sent after a lineup fails validation. The AI fixes its own lineup instead of code blindly patching it.
    public static func revision(_ findings: [Finding], phase: String) -> String {
        let problems = findings.violations.map { "- \($0.message)" }.joined(separator: "\n")
        return """
        Your \(phase) has problems that must be fixed:
        \(problems)

        Return the corrected, complete JSON in exactly the same format. Fix every problem listed. Keep everything else the same unless a change is needed to fix a problem.
        """
    }

    // MARK: - Pieces

    static func header(_ context: GameContext) -> String {
        var text = "You are the highest rated youth baseball coach for \(context.ageGroup.flatMap { $0.isEmpty ? nil : $0 } ?? "youth") players.\n"
        text += "\n\(priorityDirectives[context.priority]!)\n"
        text += "\n\(weightingDirectives[context.weighting]!)\n"
        return text
    }

    static func footer(_ context: GameContext) -> String {
        var text = "\nScouting Report (the opponent; use it where it should change your choices): " + (context.scoutingReport.isEmpty ? "None provided" : context.scoutingReport)
        if !context.notesForAI.isEmpty {
            text += "\n\nNotes for AI: \(context.notesForAI)"
        }
        return text
    }

    static func rulesText(_ rules: [TeamRule], numberingFrom start: Int, emptyText: String) -> String {
        guard !rules.isEmpty else { return emptyText }
        return rules.enumerated().map { "\($0.offset + start). \($0.element.text)" }.joined(separator: "\n")
    }

    static func lockedText(_ context: GameContext, ids: PromptIDs) -> String {
        let locks = context.locks.filter { $0.inning <= context.innings }
        guard !locks.isEmpty else { return "None" }
        return Dictionary(grouping: locks, by: \.inning)
            .sorted { $0.key < $1.key }
            .map { inning, locks in
                "Inning \(inning): " + locks.map { "\(context.name($0.player)) (\(ids.token($0.player))) at \($0.slot)" }.joined(separator: ", ")
            }
            .joined(separator: "\n")
    }

    static func describe(_ lineup: Lineup, context: GameContext, ids: PromptIDs) -> String {
        lineup.innings.prefix(context.innings).enumerated().map { index, inning in
            var parts = Position.allCases.compactMap { position in
                inning.positions[position].map { "\(position.label): \(context.name($0)) (\(ids.token($0)))" }
            }
            if !inning.sitting.isEmpty {
                parts.append("SIT: " + inning.sitting.map { "\(context.name($0)) (\(ids.token($0)))" }.joined(separator: ", "))
            }
            return "Inning \(index + 1): " + parts.joined(separator: ", ")
        }
        .joined(separator: "\n")
    }

    static func rating(_ player: PlayerSnapshot, _ key: RatingKey) -> String {
        "\(key.label): \(player.ratings[key].map(String.init) ?? "unrated")"
    }

    static func coachNotes(_ player: PlayerSnapshot, context: GameContext) -> String {
        let availability = context.availability(of: player.id)
        var notes: [String] = []
        if !player.notes.isEmpty { notes.append(player.notes) }
        if !availability.note.isEmpty { notes.append("Today: \(availability.note)") }
        return notes.isEmpty ? "none" : notes.joined(separator: " | ")
    }

    static func availabilityLine(_ player: PlayerSnapshot, context: GameContext) -> String? {
        let a = context.availability(of: player.id)
        guard a.isPartial else { return nil }
        let from = a.arrivesInning ?? 1
        let through = a.leavesAfterInning ?? context.innings
        return "Availability: innings \(from)-\(through) only"
    }

    static func battingPlayerText(_ player: PlayerSnapshot, context: GameContext, ids: PromptIDs) -> String {
        var text = "---\nName: \(player.name)\nID: \(ids.token(player.id))"
        if context.weighting.usesRatings {
            let keys: [RatingKey] = [.plateDiscipline, .contactAbility, .battingPower, .runSpeed]
            text += "\nSubjective Ratings (1-5): " + keys.map { rating(player, $0) }.joined(separator: ", ")
        }
        if context.weighting.usesStats, let b = player.stats?.batting, b.pa > 0 {
            text += "\nGameChanger Stats: PA: \(b.pa), AVG: \(f3(b.avg)), OBP: \(f3(b.obp)), SLG: \(f3(b.slg)), K%: \(pct(b.kRate)), BB%: \(pct(b.bbRate)), SB: \(b.sb), SB%: \(pct(b.sbPct, digits: 0))"
        }
        if let line = availabilityLine(player, context: context) { text += "\n\(line)" }
        text += "\nCoach Notes: \(coachNotes(player, context: context))"
        return text
    }

    static func defensivePlayerText(_ player: PlayerSnapshot, context: GameContext, ids: PromptIDs) -> String {
        var text = "---\nName: \(player.name)\nID: \(ids.token(player.id))"
        let profile = player.profile
        if context.weighting.usesRatings {
            var keys: [RatingKey] = [.runSpeed, .baseballIQ, .attention, .fieldingHands, .throwAccuracy, .armStrength, .flyBallAbility]
            if profile.canPlay(.p) { keys += [.pitchControl, .pitchVelocity, .pitchComposure] }
            if profile.canPlay(.c) { keys.append(.catcherAbility) }
            text += "\nSubjective Ratings (1-5): " + keys.map { rating(player, $0) }.joined(separator: ", ")
        }
        if context.weighting.usesStats, let f = player.stats?.fielding, f.tc > 0 {
            text += "\nGameChanger Stats: FPCT: \(f3(f.fpct)), Errors: \(f.e), TC: \(f.tc)"
        }
        if context.weighting.usesStats, let f = player.stats?.fielding, f.catcherOuts > 0 {
            text += "\nCatching Stats: Innings caught: \(String(format: "%.1f", f.catcherInnings)), Passed balls: \(f.passedBalls), SB allowed: \(f.stolenBasesAllowed), CS: \(f.caughtStealing)"
        }
        if context.weighting.usesStats, let p = player.stats?.pitching, p.outs > 0 {
            text += "\nPitching Stats: IP: \(p.ipText), ERA: \(f2(p.era)), WHIP: \(f2(p.whip)), K: \(p.so), BB: \(p.bb)"
        }
        let yesNo = { (p: Position) in profile.canPlay(p) ? "yes" : "no" }
        text += "\nPremium Position Eligibility: Pitch: \(yesNo(.p)), Catch: \(yesNo(.c)), SS: \(yesNo(.ss)), 1B: \(yesNo(.first))"
        let strengths = profile.strengths.map { "\($0.label) (\(profile[$0].label))" }
        text += "\nPosition Strengths: " + (strengths.isEmpty ? "Not specified" : strengths.joined(separator: " > "))
        if !profile.ineligible.isEmpty {
            text += "\nCannot play: " + profile.ineligible.map(\.label).joined(separator: ", ")
        }
        if let line = availabilityLine(player, context: context) { text += "\n\(line)" }
        text += "\nCoach Notes: \(coachNotes(player, context: context))"
        return text
    }

    static func f3(_ value: Double?) -> String {
        guard let value else { return "-" }
        let s = String(format: "%.3f", value)
        return s.hasPrefix("0.") ? String(s.dropFirst()) : s
    }

    static func f2(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }

    static func pct(_ value: Double?, digits: Int = 1) -> String {
        value.map { String(format: "%.\(digits)f%%", $0 * 100) } ?? "N/A"
    }
}
