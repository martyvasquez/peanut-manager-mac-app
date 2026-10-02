import SwiftUI
import AppKit
import LineupKit

/// Dugout lineup card: batting order with jersey numbers and every inning's position.
struct LineupCardView: View {
    let title: String
    let subtitle: String
    let rows: [PlayerSnapshot]
    let lineup: Lineup
    let innings: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    cell("#", width: 28, bold: true)
                    cell("No.", width: 36, bold: true)
                    cell("Player", width: 180, bold: true, alignment: .leading)
                    ForEach(1...innings, id: \.self) { cell("\($0)", width: 46, bold: true) }
                }
                .background(Color.gray.opacity(0.15))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, player in
                    GridRow {
                        cell(lineup.battingOrder.contains(player.id) ? "\(index + 1)" : "", width: 28)
                        cell(player.jersey ?? "", width: 36)
                        cell(player.name, width: 180, alignment: .leading)
                        ForEach(1...innings, id: \.self) { inning in
                            let slot = lineup.slot(of: player.id, inning: inning)
                            cell(slot.map { $0 == .bench ? "—" : $0.description } ?? "", width: 46, bold: slot != .bench)
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
        }
        .padding(24)
        .foregroundStyle(.black)
        .background(.white)
    }

    private func cell(_ text: String, width: CGFloat, bold: Bool = false, alignment: Alignment = .center) -> some View {
        Text(text)
            .font(.system(size: 12, weight: bold ? .semibold : .regular).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: width, height: 24, alignment: alignment)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}

enum LineupCardPrinter {
    @MainActor
    static func print(model: GameModel) {
        let game = model.game
        let card = LineupCardView(
            title: "\(game.team?.name ?? "") vs \(game.opponent)",
            subtitle: game.date.formatted(date: .complete, time: .shortened),
            rows: model.rows.filter { model.context.availability(of: $0.id).present },
            lineup: model.lineup,
            innings: game.innings
        )
        let hosting = NSHostingView(rootView: card)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = .landscape
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let operation = NSPrintOperation(view: hosting, printInfo: info)
        operation.jobTitle = "Lineup vs \(game.opponent)"
        operation.run()
    }
}
