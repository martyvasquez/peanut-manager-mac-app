import SwiftUI
import SwiftData
import LineupKit

/// One game, in the night-before order: the batting order, then positions.
struct GameScreen: View {
    @State private var model: GameModel
    @Environment(\.undoManager) private var undoManager

    init(game: Game) {
        _model = State(initialValue: GameModel(game: game))
    }

    var body: some View {
        Group {
            switch model.step {
            case .battingOrder: BattingOrderList(model: model)
            case .positions: PositionsBoard(model: model)
            }
        }
        .navigationTitle(model.game.opponent.isEmpty ? "Game" : model.game.opponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Step", selection: Binding(
                    get: { model.step },
                    set: { step in
                        if step == .positions { model.preparePositions() } else { model.step = step }
                    }
                )) {
                    Text("Batting").tag(GameModel.Step.battingOrder)
                    Text("Positions").tag(GameModel.Step.positions)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                    .disabled(!canUndo(after: model.document))
            }
        }
        .onAppear(perform: debugSetup)
    }

    /// Takes the document so the button checks again after every edit (UndoManager isn't observable).
    private func canUndo(after _: LineupDocument) -> Bool { undoManager?.canUndo ?? false }

    private func debugSetup() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "PMStep") {
        case "batting": model.step = .battingOrder
        case "positions": model.preparePositions()
        default: break
        }
        #endif
    }
}

/// Step 1: kids in batting order. Drag to reorder, swipe to take a kid out, tap a kid below to add them.
struct BattingOrderList: View {
    let model: GameModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let slots = model.battingSlots
        let unplaced = model.unplacedBatters
        List {
            Section {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, id in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.body.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: 24, alignment: .trailing)
                        if let id, let player = model.context.player(id) {
                            Text(player.name)
                        } else {
                            Text("Empty").foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        if let id {
                            Button("Remove", role: .destructive) { model.removeBatter(id, undoManager: undoManager) }
                        }
                    }
                    .moveDisabled(id == nil)
                }
                .onMove { from, to in
                    guard let source = from.first, let id = slots[source] else { return }
                    withAnimation { model.placeBatter(id, inSlot: to > source ? to - 1 : to, undoManager: undoManager) }
                }
            }
            if !unplaced.isEmpty {
                Section("Not in the Order") {
                    ForEach(unplaced) { player in
                        Button {
                            withAnimation { model.placeBatter(player.id, inSlot: nil, undoManager: undoManager) }
                        } label: {
                            Label(player.name, systemImage: "plus.circle.fill")
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }
}
