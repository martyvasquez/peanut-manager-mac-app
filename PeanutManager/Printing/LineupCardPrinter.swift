import SwiftUI
import AppKit
import PDFKit
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
                            cell(slot.map { $0 == .bench ? "SIT" : $0.description } ?? "", width: 46, bold: slot != .bench)
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
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = .landscape
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "PMPrintTo") {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: path)
        }
        #endif
        // A SwiftUI view outside a window prints blank, so draw the card into a page-sized PDF and print that.
        guard let document = pdf(card.environment(\.colorScheme, .light), page: info.paperSize),
              let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: false) else { return }
        operation.jobTitle = "Lineup vs \(game.opponent)"
        #if DEBUG
        if UserDefaults.standard.string(forKey: "PMPrintTo") != nil { operation.showsPrintPanel = false; operation.showsProgressPanel = false }
        #endif
        operation.run()
    }

    /// The view as a one-page vector PDF the size of the paper, at the top and centered across,
    /// shrunk to fit when it's wider or taller than the page.
    @MainActor
    private static func pdf(_ view: some View, page: CGSize) -> PDFDocument? {
        let data = NSMutableData()
        ImageRenderer(content: view).render { size, render in
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
        return PDFDocument(data: data as Data)
    }
}
