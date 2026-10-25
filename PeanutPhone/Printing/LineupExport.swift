import SwiftUI
import UIKit
import LineupKit

/// The dugout lineup card (the Mac's `LineupCardView`) as a PDF to print or send, and the lineup as text for a
/// team chat. Made when asked for, not on every redraw.
@MainActor
enum LineupExport {
    /// Landscape US Letter, as the Mac prints it.
    static let page = CGSize(width: 792, height: 612)

    static func print(_ model: GameModel) {
        guard let data = pdf(model) else { return }
        let info = UIPrintInfo.printInfo()
        info.orientation = .landscape
        info.outputType = .general
        info.jobName = "Lineup vs \(model.game.opponent)"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }

    static func sharePDF(_ model: GameModel) {
        guard let data = pdf(model) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "Lineup vs \(fileSafe(model.game.opponent)).pdf")
        do { try data.write(to: url) } catch { return }
        present([url])
    }

    static func shareText(_ model: GameModel) {
        present([text(model)])
    }

    // MARK: Making them

    static func card(_ model: GameModel) -> LineupCardView {
        let game = model.game
        return LineupCardView(
            title: "\(game.team?.name ?? "") vs \(game.opponent)",
            subtitle: game.date.formatted(date: .complete, time: .shortened),
            rows: model.rows.filter { model.context.availability(of: $0.id).present },
            lineup: model.lineup,
            innings: game.innings
        )
    }

    /// The card as a one-page vector PDF, at the top and centered across, shrunk to fit.
    static func pdf(_ model: GameModel) -> Data? {
        let data = NSMutableData()
        ImageRenderer(content: card(model).environment(\.colorScheme, .light)).render { size, render in
            var box = CGRect(origin: .zero, size: page)
            guard size.width > 0, size.height > 0,
                  let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            let scale = min(1, page.width / size.width, page.height / size.height)
            context.beginPDFPage(nil)
            context.translateBy(x: (page.width - size.width * scale) / 2, y: page.height - size.height * scale)
            context.scaleBy(x: scale, y: scale)
            render(context)
            context.endPDFPage()
            context.closePDF()
        }
        return data.length > 0 ? data as Data : nil
    }

    /// "1. Gray Mitchell #13 — CF, LF, SIT, 1B, LF, SIT", one line per kid in batting order.
    static func text(_ model: GameModel) -> String {
        let game = model.game
        let lineup = model.lineup
        var lines = ["\(game.team?.name ?? "") vs \(game.opponent)", game.date.formatted(date: .abbreviated, time: .shortened), ""]
        let rows = model.rows.filter { model.context.availability(of: $0.id).present }
        for (index, player) in rows.enumerated() {
            let order = lineup.battingOrder.contains(player.id) ? "\(index + 1). " : ""
            let number = player.jersey.map { " #\($0)" } ?? ""
            let spots = (1...max(game.innings, 1)).map { lineup.slot(of: player.id, inning: $0)?.description ?? "–" }
            lines.append("\(order)\(player.name)\(number) — \(spots.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func fileSafe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        return cleaned.isEmpty ? "Game" : cleaned
    }

    /// The share sheet, over whatever is showing.
    private static func present(_ items: [Any]) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }
}
