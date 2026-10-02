import Foundation
import Testing
@testable import LineupKit

struct EngineTests {
    let players = makeTeam()
    var context: GameContext { GameContext(innings: 6, players: players) }

    @Test func validDefenseOnFirstTryIsAcceptedAsIs() async throws {
        let client = ScriptedClient([defenseJSON(validLineup(players), players: players)])
        let result = try await LineupEngine(client: client, model: "m").defense(context, battingOrder: players.map(\.id))
        #expect(result.revisions == 0)
        #expect(result.findings.isEmpty)
        #expect(result.adjustedCells.isEmpty)
        #expect(result.innings == validLineup(players).innings)
        #expect(result.inningReasons.first == "inning 1")
        #expect(client.requests.count == 1)
    }

    @Test func violationsGoBackToTheAIWhichFixesThem() async throws {
        var broken = validLineup(players)
        broken.innings[0].positions[.rf] = broken.innings[0].positions[.lf]
        let client = ScriptedClient([defenseJSON(broken, players: players), defenseJSON(validLineup(players), players: players)])
        let result = try await LineupEngine(client: client, model: "m").defense(context, battingOrder: players.map(\.id))

        #expect(result.revisions == 1)
        #expect(result.findings.isEmpty)
        #expect(result.adjustedCells.isEmpty)
        #expect(result.provenance.values.contains(.aiRevised))
        // The revise turn quotes the exact problem back to the model.
        let revise = try #require(client.requests.last?.messages.last?.content)
        #expect(revise.contains("more than one place"))
        #expect(result.usage.cost == 0.02)
    }

    @Test func persistentViolationsFallBackToDisclosedSafetyNet() async throws {
        var broken = validLineup(players)
        broken.innings[0].positions[.rf] = broken.innings[0].positions[.lf]
        let reply = defenseJSON(broken, players: players)
        let client = ScriptedClient([reply, reply, reply])
        let events = EventLog()
        let result = try await LineupEngine(client: client, model: "m", maxRevisions: 2)
            .defense(context, battingOrder: players.map(\.id)) { events.append($0) }
        let progressEvents = events.all

        #expect(result.revisions == 2)
        #expect(result.findings.isEmpty)
        #expect(!result.adjustedCells.isEmpty)
        #expect(progressEvents.contains(.adjusting(.defense)))
    }

    @Test func unreadableReplyIsRetried() async throws {
        let client = ScriptedClient(["Sorry, here's my thinking...", defenseJSON(validLineup(players), players: players)])
        let result = try await LineupEngine(client: client, model: "m").defense(context, battingOrder: players.map(\.id))
        #expect(result.revisions == 1)
        #expect(result.findings.isEmpty)
    }

    @Test func infeasibleGameNeverCallsTheAI() async {
        var ctx = context
        for player in players.prefix(5) { ctx.availability[player.id] = .absent }
        let client = ScriptedClient([])
        await #expect(throws: GenerationError.self) {
            try await LineupEngine(client: client, model: "m").defense(ctx, battingOrder: [])
        }
        #expect(client.requests.isEmpty)
    }

    @Test func lockedCellsAreMarkedCoachAndPromptMentionsThem() async throws {
        var ctx = context
        let lineup = validLineup(players)
        let ss = lineup.innings[0].positions[.ss]!
        ctx.locks = [Lock(inning: 1, player: ss, slot: .field(.ss))]
        let client = ScriptedClient([defenseJSON(lineup, players: players)])
        let result = try await LineupEngine(client: client, model: "m").defense(ctx, battingOrder: players.map(\.id))
        #expect(result.provenance[CellKey(inning: 1, player: ss)] == .coach)
        let prompt = try #require(client.requests.first?.messages.first?.content)
        #expect(prompt.contains("Inning 1: \(players.first { $0.id == ss }!.name)"))
    }

    @Test func battingOrderRevisesMissingPlayer() async throws {
        let short = Array(players.map(\.id).dropLast())
        let client = ScriptedClient([battingJSON(short, players: players), battingJSON(players.map(\.id), players: players)])
        let result = try await LineupEngine(client: client, model: "m").battingOrder(context)
        #expect(result.revisions == 1)
        #expect(result.order == players.map(\.id))
        #expect(result.findings.isEmpty)
        #expect(result.reasons[players[0].id] == "why")
    }

    @Test func battingFeedbackIncludesCurrentOrder() {
        let ids = PromptIDs(players: players)
        let prompt = Prompts.battingOrder(context, ids: ids, currentOrder: players.map(\.id), feedback: "Lead off with Player 3")
        #expect(prompt.contains("CURRENT BATTING ORDER"))
        #expect(prompt.contains("Lead off with Player 3"))
        #expect(!Prompts.battingOrder(context, ids: ids).contains("COACH FEEDBACK"))
    }

    @Test func promptStatesUnratedInsteadOfAverage() {
        // v1 blind spot #13: unrated became 3.
        let prompt = Prompts.battingOrder(context, ids: PromptIDs(players: players))
        #expect(prompt.contains("Plate Discipline: unrated"))
        #expect(!prompt.contains("Plate Discipline: 3"))
    }

    @Test func promptIncludesScoutingReport() {
        var ctx = context
        ctx.scoutingReport = "They bunt a lot"
        #expect(Prompts.battingOrder(ctx, ids: PromptIDs(players: players)).contains("They bunt a lot"))
        #expect(Prompts.defense(ctx, battingOrder: players.map(\.id), ids: PromptIDs(players: players)).contains("They bunt a lot"))
    }

    @Test func promptIncludesCoachNotes() {
        // v1 blind spot #15: player notes never reached the lineup AI.
        var team = players
        team[0].notes = "Afraid of fly balls"
        let ctx = GameContext(innings: 6, players: team)
        let prompt = Prompts.defense(ctx, battingOrder: team.map(\.id), ids: PromptIDs(players: team))
        #expect(prompt.contains("Afraid of fly balls"))
    }

    @Test func idsInProseBecomeNames() {
        let ids = PromptIDs(players: players)
        #expect(ids.humanize("P1 leads off; P12 catches. SP2 stays.", players: players) == "Player leads off; Player catches. SP2 stays.")
    }

    @Test func acceptsV1StyleObjectReferences() throws {
        let ids = PromptIDs(players: players)
        let json = """
        {"defense": [{"inning": 1, "P": {"id": "P1", "name": "Player 1"}, "C": {"id": "x", "name": "Player 4"}, "sit": []}]}
        """
        let decoded = try JSONExtraction.decode(DefenseResponse.self, from: json).mapped(ids: ids, players: players, innings: 1)
        #expect(decoded.innings[0].positions[.p] == players[0].id)
        #expect(decoded.innings[0].positions[.c] == players[3].id)
    }
}

final class EventLog: @unchecked Sendable {
    private var events: [GenerationProgress] = []
    private let lock = NSLock()
    func append(_ event: GenerationProgress) { lock.withLock { events.append(event) } }
    var all: [GenerationProgress] { lock.withLock { events } }
}
