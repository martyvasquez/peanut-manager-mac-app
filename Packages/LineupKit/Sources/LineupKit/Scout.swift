import Foundation

/// Scout prompts, ported from v1's stats analysis (`lib/ai/claude-client.ts`, `app/api/stats/analyze/route.ts`).
/// Deliberate v2 changes (plan §5):
/// - the coach's ratings, notes and positions are inputs, not just GameChanger stats
/// - claims cite fact IDs instead of writing their own "supporting_stats" text
/// - one player per request, so only players whose inputs changed are re-assessed
/// - eye-vs-data, development focus and data confidence are asked for explicitly
/// - team totals are computed from counts, not averages of averages; K% uses PA, not AB
public enum ScoutPrompts {
    public static let playerSystem = """
    You are a youth baseball player analyst. Analyze a player's statistics, coach ratings and coach notes to identify strengths and weaknesses.

    INPUTS YOU WILL RECEIVE:
    - A fact sheet. Each fact has an ID in brackets: GameChanger season stats (rates already computed), the coach's 1-5 skill ratings, where the coach plays the player, and the coach's notes.
    - A skill with no rating is unknown, not average.

    ANALYSIS PRINCIPLES:
    1. Be constructive - this is for youth development, not criticism
    2. Back up every claim with facts: list the fact IDs in "evidence". Don't write statistics in your text; the app shows the cited values next to your words.
    3. Consider the context of youth baseball (e.g., .300 AVG is solid, high strikeouts are common)
    4. Identify 2-4 strengths and 1-3 areas for improvement per player
    5. Provide actionable insights when possible
    6. Small samples are noisy. Weigh the stats by plate appearances and chances, and say where the coach's ratings and the stats disagree.

    CATEGORIES TO CONSIDER:
    - Batting: Contact, Power, Plate Discipline, Speed
    - Fielding: Hands, Range, Arm Strength, Consistency
    - Pitching and catching, if the player does either

    OUTPUT FORMAT:
    Return valid JSON only. No markdown, no explanation outside the JSON structure.
    """

    public static func player(_ player: PlayerSnapshot, facts: FactSheet, ageGroup: String?) -> String {
        let jersey = player.jersey.map { " (#\($0))" } ?? ""
        let age = ageGroup.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        return """
        Analyze the following youth baseball player\(age).

        PLAYER: \(player.name)\(jersey)

        FACT SHEET:
        \(facts.promptText)

        Provide:
        1. 2-4 strengths, each citing the facts that support it
        2. 1-3 areas for improvement, each citing the facts that support it
        3. A brief summary (1-2 sentences)
        4. Batting role (e.g., "table-setter", "contact", "gap power", "developing") and zone in the lineup: top, middle or bottom
        5. Defensive fit at each position the coach plays them, plus any position the facts suggest: strong, solid, developing or not_recommended. Say so when the facts disagree with where the coach plays them.
        6. Where the coach's ratings and the stats disagree, and which to trust given the sample size (null if they agree or there's nothing to compare)
        7. 1-3 development focuses, each with a drill
        8. Data confidence: high, medium or low, and why

        Return your analysis in this exact JSON format:
        {
          "summary": "A reliable contact hitter who gets on base consistently. Focus on driving the ball with more authority.",
          "strengths": [
            { "category": "Contact", "description": "Rarely strikes out and puts the ball in play", "evidence": ["avg", "k_rate"] }
          ],
          "weaknesses": [
            { "category": "Power", "description": "Limited extra-base hit production", "evidence": ["slg", "xbh"] }
          ],
          "batting": { "role": "table-setter", "zone": "top", "reason": "Gets on base and runs well" },
          "defense": [
            { "position": "SS", "fit": "solid", "reason": "Sure hands; arm is still developing", "evidence": ["fpct", "rating.fielding_arm_strength"] }
          ],
          "eye_vs_data": null,
          "development_focus": [
            { "focus": "Drive the ball", "drill": "Tee work on line drives to the gaps" }
          ],
          "data_confidence": { "level": "medium", "reason": "About half a season of plate appearances; no fielding ratings" }
        }
        """
    }

    public static let teamSystem = """
    You are a youth baseball team analyst. Analyze aggregate team statistics to identify team-wide strengths, weaknesses, and provide practice recommendations.

    INPUTS YOU WILL RECEIVE:
    - A team fact sheet and each player's fact sheet. Each fact has an ID in brackets.
    - Individual player assessments (summaries)

    ANALYSIS PRINCIPLES:
    1. Focus on actionable insights for coaches
    2. Be constructive - this is for youth development
    3. Back up claims with facts: list the fact IDs in "evidence". Don't write statistics in your text; the app shows the cited values next to your words.
    4. Consider youth baseball context
    5. Provide specific practice drill recommendations

    KEY AREAS TO ANALYZE:
    - Team batting approach (contact vs power, discipline)
    - Team fielding consistency
    - Defensive depth and flexibility, especially pitcher, catcher and up the middle
    - Areas where multiple players struggle

    OUTPUT FORMAT:
    Return valid JSON only. No markdown, no explanation outside the JSON structure.
    """

    public static func team(_ players: [PlayerSnapshot], assessments: [PlayerID: PlayerAssessment], teamFacts: FactSheet, ids: PromptIDs, ageGroup: String?) -> String {
        let age = ageGroup.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        let roster = players.map { player in
            let token = ids.token(player.id)
            var text = "---\n\(token): \(player.name)"
            if let a = assessments[player.id] {
                text += "\nAssessment: \(a.snapshot)"
                text += "\nBatting: \(a.battingRole)" + (a.battingZone.map { ", \($0.rawValue) of the order" } ?? "")
                let fits = a.defense.filter { $0.fit <= .solid }.map { "\($0.position.label) (\($0.fit.label.lowercased()))" }
                if !fits.isEmpty { text += "\nBest positions: " + fits.joined(separator: ", ") }
            }
            let facts = FactSheet.player(player).facts.filter { !$0.id.hasPrefix("note.") }
            text += "\n" + facts.map { "[\(token).\($0.id)] \($0.label): \($0.value)" }.joined(separator: "\n")
            return text
        }
        .joined(separator: "\n")

        return """
        Analyze the following youth baseball team\(age) based on its facts and individual player assessments.

        TEAM FACT SHEET:
        \(teamFacts.promptText)

        PLAYERS:
        \(roster)

        Provide team-level analysis in this exact JSON format. Refer to players by ID (P1, P2, …):
        {
          "team_strengths": [
            { "category": "Plate Discipline", "description": "Team draws walks at an above-average rate", "evidence": ["team.bb_rate"] }
          ],
          "team_weaknesses": [
            { "category": "Strikeouts", "description": "Contact is the team's biggest gap", "evidence": ["team.k_rate", "P4.k_rate"] }
          ],
          "practice_recommendations": [
            { "focus_area": "Contact hitting", "drill_suggestions": "Soft toss, tee work focusing on bat-to-ball contact, two-strike approach drills", "priority": "high" }
          ],
          "lineup_insights": {
            "best_leadoff_candidates": ["P1", "P5"],
            "middle_of_order": ["P3", "P7"],
            "defensive_core": ["P2", "P6"],
            "defensive_concerns": ["Only two players can catch"]
          },
          "summary": "A brief 2-3 sentence summary of the team's overall profile and top priorities."
        }
        """
    }

    static func revision(_ problems: [String]) -> String {
        "Your reply has these problems:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
            + "\n\nCite only fact IDs that appear in brackets in the fact sheet. Reply with the complete corrected JSON only."
    }
}

public enum ScoutError: Error, LocalizedError {
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The model's assessment couldn't be read. Try again or pick another model."
        }
    }
}

/// Assesses players and the team. Code supplies the facts and checks every citation;
/// a reply citing a fact that doesn't exist goes back once for the model to fix.
public struct Scout: Sendable {
    public var client: any LLMClient
    public var model: String

    public init(client: any LLMClient, model: String) {
        self.client = client
        self.model = model
    }

    public func assess(_ player: PlayerSnapshot, ageGroup: String? = nil) async throws -> PlayerAssessment {
        let facts = FactSheet.player(player)
        let prompt = ScoutPrompts.player(player, facts: facts, ageGroup: ageGroup)
        let (raw, cost) = try await ask(PlayerAssessmentResponse.self, system: ScoutPrompts.playerSystem, prompt: prompt, maxTokens: 16000) { raw in
            let mapped = Self.map(raw, facts: facts)
            return Grounding.problems(mapped.strengths + mapped.weaknesses, defense: mapped.defense, facts: facts)
        }
        var assessment = Self.map(raw, facts: facts)
        assessment.strengths = assessment.strengths.map { Grounding.keepingResolved($0, facts: facts) }
        assessment.weaknesses = assessment.weaknesses.map { Grounding.keepingResolved($0, facts: facts) }
        assessment.defense = assessment.defense.map { var fit = $0; fit.evidence = fit.evidence.filter(facts.contains); return fit }
        assessment.model = model
        assessment.cost = cost
        return assessment
    }

    public func assessTeam(_ players: [PlayerSnapshot], assessments: [PlayerID: PlayerAssessment], ageGroup: String? = nil) async throws -> TeamAssessment {
        let ids = PromptIDs(players: players)
        let teamFacts = FactSheet.team(players)
        let facts = Self.citable(players, teamFacts: teamFacts, ids: ids)
        let prompt = ScoutPrompts.team(players, assessments: assessments, teamFacts: teamFacts, ids: ids, ageGroup: ageGroup)
        let (raw, cost) = try await ask(TeamAssessmentResponse.self, system: ScoutPrompts.teamSystem, prompt: prompt, maxTokens: 16000) { raw in
            Grounding.problems(((raw.team_strengths ?? []) + (raw.team_weaknesses ?? [])).map(\.claim), facts: facts)
        }
        func resolve(_ refs: [PlayerRef]?) -> [PlayerID] {
            var seen = Set<PlayerID>()
            return (refs ?? []).compactMap { $0.resolve(ids: ids, players: players) }.filter { seen.insert($0).inserted }
        }
        func prose(_ text: String) -> String { ids.humanize(text, players: players) }
        func claims(_ raw: [PlayerAssessmentResponse.RawClaim]?) -> [Claim] {
            (raw ?? []).map { var c = Grounding.keepingResolved($0.claim, facts: facts); c.detail = prose(c.detail); return c }
        }
        return TeamAssessment(
            summary: prose(raw.summary ?? ""),
            strengths: claims(raw.team_strengths),
            weaknesses: claims(raw.team_weaknesses),
            leadoff: resolve(raw.lineup_insights?.best_leadoff_candidates),
            middleOrder: resolve(raw.lineup_insights?.middle_of_order),
            defensiveCore: resolve(raw.lineup_insights?.defensive_core),
            defensiveConcerns: (raw.lineup_insights?.defensive_concerns ?? []).map(prose),
            practice: (raw.practice_recommendations ?? []).compactMap { item in
                guard let focus = item.focus_area, !focus.isEmpty else { return nil }
                return PracticeItem(focus: focus, drills: prose(item.drill_suggestions ?? ""), priority: PracticeItem.Priority(rawValue: item.priority?.lowercased() ?? "") ?? .medium)
            },
            facts: facts, model: model, cost: cost, assessedAt: .now
        )
    }

    /// Team facts plus each player's, with player facts prefixed by their prompt ID ("P3.obp").
    static func citable(_ players: [PlayerSnapshot], teamFacts: FactSheet, ids: PromptIDs) -> FactSheet {
        var facts = teamFacts.facts
        for player in players {
            let first = player.name.components(separatedBy: " ").first ?? player.name
            for fact in FactSheet.player(player).facts where !fact.id.hasPrefix("note.") {
                facts.append(Fact("\(ids.token(player.id)).\(fact.id)", "\(first) \(fact.label)", fact.value))
            }
        }
        return FactSheet(facts)
    }

    /// One request, plus one retry when the reply is unreadable or cites facts that don't exist.
    private func ask<T: Decodable>(_ type: T.Type, system: String, prompt: String, maxTokens: Int, problems: (T) -> [String]) async throws -> (T, Double?) {
        var messages = [LLMMessage(.user, prompt)]
        var usage = LLMUsage()
        var best: T?
        for attempt in 0..<2 {
            let response = try await client.complete(LLMRequest(model: model, system: system, messages: messages, maxTokens: maxTokens))
            usage = usage + response.usage
            let found: [String]
            if let decoded = try? JSONExtraction.decode(T.self, from: response.text) {
                best = decoded
                found = problems(decoded)
            } else {
                found = ["Your reply could not be read as the requested JSON."]
            }
            guard !found.isEmpty, attempt == 0 else { break }
            messages.append(LLMMessage(.assistant, response.text))
            messages.append(LLMMessage(.user, ScoutPrompts.revision(found)))
        }
        guard let best else { throw ScoutError.unreadable }
        return (best, usage.cost)
    }

    static func map(_ raw: PlayerAssessmentResponse, facts: FactSheet) -> PlayerAssessment {
        let zone = raw.batting?.zone?.lowercased()
        let defense: [DefensiveFit] = (raw.defense ?? []).compactMap { d in
            guard let position = Position(label: d.position),
                  let fit = PositionFit(rawValue: d.fit.lowercased().replacingOccurrences(of: " ", with: "_")) else { return nil }
            return DefensiveFit(position: position, fit: fit, reason: d.reason ?? "", evidence: d.evidence ?? [])
        }
        let eye = raw.eye_vs_data?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlayerAssessment(
            snapshot: raw.summary ?? "",
            strengths: (raw.strengths ?? []).map(\.claim),
            weaknesses: (raw.weaknesses ?? []).map(\.claim),
            battingRole: raw.batting?.role ?? "",
            battingZone: BattingZone.allCases.first { zone?.contains($0.rawValue) == true },
            battingReason: raw.batting?.reason ?? "",
            defense: defense.sorted { ($0.fit, $0.position) < ($1.fit, $1.position) },
            eyeVsData: (eye?.isEmpty ?? true) || eye?.lowercased() == "null" ? nil : eye,
            development: (raw.development_focus ?? []).compactMap { f in f.focus.map { DevelopmentFocus(focus: $0, drill: f.drill ?? "") } },
            confidence: Confidence(rawValue: raw.data_confidence?.level?.lowercased() ?? "") ?? .low,
            confidenceReason: raw.data_confidence?.reason ?? "",
            facts: facts, model: "", cost: nil, assessedAt: .now
        )
    }
}
