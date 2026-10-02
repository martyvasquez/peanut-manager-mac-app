import Foundation

// MARK: - Model client abstraction

public struct LLMMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

public struct LLMRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [LLMMessage]
    public var maxTokens: Int

    public init(model: String, system: String, messages: [LLMMessage], maxTokens: Int) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
    }
}

public struct LLMUsage: Codable, Sendable, Hashable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// USD, when the provider reports it.
    public var cost: Double?

    public init(promptTokens: Int = 0, completionTokens: Int = 0, cost: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
    }

    public static func + (lhs: LLMUsage, rhs: LLMUsage) -> LLMUsage {
        let cost: Double? = (lhs.cost == nil && rhs.cost == nil) ? nil : (lhs.cost ?? 0) + (rhs.cost ?? 0)
        return LLMUsage(promptTokens: lhs.promptTokens + rhs.promptTokens, completionTokens: lhs.completionTokens + rhs.completionTokens, cost: cost)
    }
}

public struct LLMResponse: Sendable {
    public var text: String
    public var model: String?
    public var usage: LLMUsage

    public init(text: String, model: String? = nil, usage: LLMUsage = LLMUsage()) {
        self.text = text
        self.model = model
        self.usage = usage
    }
}

/// Anything that can answer a chat request (OpenRouter in the app, scripted fakes in tests).
public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

// MARK: - Results

public enum GenerationPhase: String, Sendable {
    case battingOrder = "batting order"
    case defense = "defensive lineup"
}

public enum GenerationProgress: Sendable, Equatable {
    case asking(GenerationPhase)
    case revising(GenerationPhase, round: Int, problems: Int)
    case adjusting(GenerationPhase)
}

public enum GenerationError: Error, LocalizedError {
    /// The game can't be lineup'd as set up (e.g. fewer than 9 players). Nothing was sent to the AI.
    case infeasible([Finding])

    public var errorDescription: String? {
        switch self {
        case .infeasible(let findings): findings.first?.message ?? "This game can't be lined up as set up."
        }
    }
}

public struct BattingResult: Sendable {
    public var order: [PlayerID]
    public var reasons: [PlayerID: String]
    public var rationale: String
    /// Validation after the final step. Empty unless the safety net couldn't fix something.
    public var findings: [Finding]
    public var revisions: Int
    public var adjustedByApp: Bool
    public var usage: LLMUsage
}

public struct DefenseResult: Sendable {
    public var innings: [InningAssignment]
    public var inningReasons: [String]
    public var rationale: String
    public var warnings: [String]
    public var aiRuleNotes: [AIRuleNote]
    public var findings: [Finding]
    public var revisions: Int
    public var provenance: [CellKey: Provenance]
    public var usage: LLMUsage

    public var adjustedCells: [CellKey] { provenance.filter { $0.value == .appAdjusted }.map(\.key) }
}

// MARK: - Engine

/// AI decides; code guarantees. Asks the model for a lineup, validates it, sends exact problems back
/// for the model to fix (up to `maxRevisions` times), and only then falls back to the disclosed safety net.
public struct LineupEngine: Sendable {
    public var client: any LLMClient
    public var model: String
    public var maxRevisions: Int

    public init(client: any LLMClient, model: String, maxRevisions: Int = 2) {
        self.client = client
        self.model = model
        self.maxRevisions = maxRevisions
    }

    public func battingOrder(
        _ context: GameContext,
        progress: @Sendable (GenerationProgress) -> Void = { _ in }
    ) async throws -> BattingResult {
        let present = context.presentPlayers
        guard !present.isEmpty else {
            throw GenerationError.infeasible([Finding(.violation, .notEnoughPlayers, "Nobody is marked as coming to this game.")])
        }
        let ids = PromptIDs(players: context.players)
        var messages = [LLMMessage(.user, Prompts.battingOrder(context, ids: ids))]
        var usage = LLMUsage()
        var revisions = 0
        var best: MappedBattingOrder?
        var findings: [Finding] = []

        progress(.asking(.battingOrder))
        while true {
            let response = try await client.complete(LLMRequest(model: model, system: Prompts.battingSystem, messages: messages, maxTokens: 4000))
            usage = usage + response.usage
            do {
                let mapped = try JSONExtraction.decode(BattingOrderResponse.self, from: response.text).mapped(ids: ids, players: context.players)
                best = mapped
                findings = Validator.validateBattingOrder(mapped.order, context: context)
                if mapped.unresolved > 0 {
                    findings.append(Finding(.violation, .battingUnknownPlayer, "\(mapped.unresolved) batting order entries used a player ID that isn't in the player list."))
                }
            } catch {
                findings = [Finding(.violation, .battingUnknownPlayer, "Your reply could not be read as the requested JSON (\(error.localizedDescription)). Reply with the JSON only.")]
            }
            guard findings.hasViolations, revisions < maxRevisions else { break }
            revisions += 1
            progress(.revising(.battingOrder, round: revisions, problems: findings.violations.count))
            messages.append(LLMMessage(.assistant, response.text))
            messages.append(LLMMessage(.user, Prompts.revision(findings, phase: "batting order")))
        }

        guard let mapped = best else { throw AIResponseError.undecodable("no usable batting order after \(revisions) revisions") }
        var order = mapped.order
        var adjusted = false
        if findings.hasViolations {
            progress(.adjusting(.battingOrder))
            order = Repair.battingOrder(order, context: context)
            adjusted = true
            findings = Validator.validateBattingOrder(order, context: context)
        }
        return BattingResult(order: order, reasons: mapped.reasons, rationale: mapped.rationale, findings: findings, revisions: revisions, adjustedByApp: adjusted, usage: usage)
    }

    public func defense(
        _ context: GameContext,
        battingOrder: [PlayerID],
        currentLineup: Lineup? = nil,
        feedback: String? = nil,
        progress: @Sendable (GenerationProgress) -> Void = { _ in }
    ) async throws -> DefenseResult {
        let feasibility = Validator.feasibility(context)
        guard !feasibility.hasViolations else { throw GenerationError.infeasible(feasibility) }

        let ids = PromptIDs(players: context.players)
        let prompt = Prompts.defense(context, battingOrder: battingOrder, ids: ids, currentLineup: currentLineup, feedback: feedback)
        var messages = [LLMMessage(.user, prompt)]
        var usage = LLMUsage()
        var revisions = 0
        var first: MappedDefense?
        var latest: MappedDefense?
        var findings: [Finding] = []

        progress(.asking(.defense))
        while true {
            let response = try await client.complete(LLMRequest(model: model, system: Prompts.defensiveSystem, messages: messages, maxTokens: 8000))
            usage = usage + response.usage
            do {
                let mapped = try JSONExtraction.decode(DefenseResponse.self, from: response.text).mapped(ids: ids, players: context.players, innings: context.innings)
                if first == nil { first = mapped }
                latest = mapped
                findings = Validator.validateDefense(Lineup(battingOrder: battingOrder, innings: mapped.innings), context: context)
                for miss in mapped.unresolved {
                    let where_ = miss.position.map { " at \($0.label)" } ?? " on the bench"
                    findings.append(Finding(.violation, .unknownPlayer, "Inning \(miss.inning): a player ID\(where_) isn't in the player list.", inning: miss.inning, position: miss.position))
                }
            } catch {
                findings = [Finding(.violation, .unknownPlayer, "Your reply could not be read as the requested JSON (\(error.localizedDescription)). Reply with the JSON only.")]
            }
            guard findings.hasViolations, revisions < maxRevisions else { break }
            revisions += 1
            progress(.revising(.defense, round: revisions, problems: findings.violations.count))
            messages.append(LLMMessage(.assistant, response.text))
            messages.append(LLMMessage(.user, Prompts.revision(findings, phase: "defensive lineup")))
        }

        guard let first, let final = latest else { throw AIResponseError.undecodable("no usable defense after \(revisions) revisions") }

        var lineup = Lineup(battingOrder: battingOrder, innings: final.innings)
        var provenance: [CellKey: Provenance] = [:]
        let firstLineup = Lineup(battingOrder: battingOrder, innings: first.innings)
        for inning in 1...context.innings {
            for player in context.availablePlayers(inning: inning) {
                let key = CellKey(inning: inning, player: player.id)
                provenance[key] = firstLineup.slot(of: player.id, inning: inning) == lineup.slot(of: player.id, inning: inning) ? .ai : .aiRevised
            }
        }
        if findings.hasViolations {
            progress(.adjusting(.defense))
            let repaired = Repair.defense(lineup, context: context)
            lineup = repaired.lineup
            for key in repaired.adjusted { provenance[key] = .appAdjusted }
            findings = Validator.validateDefense(lineup, context: context)
        }
        for lock in context.locks { provenance[CellKey(inning: lock.inning, player: lock.player)] = .coach }

        var reasons = final.inningReasons
        reasons = Array(reasons.prefix(context.innings))
        while reasons.count < context.innings { reasons.append("") }

        return DefenseResult(
            innings: lineup.innings, inningReasons: reasons, rationale: final.rationale, warnings: final.warnings,
            aiRuleNotes: final.aiRuleNotes, findings: findings, revisions: revisions, provenance: provenance, usage: usage
        )
    }
}
