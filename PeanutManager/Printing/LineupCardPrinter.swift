import SwiftUI
import AppKit
import PDFKit
import LineupKit

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
