import SwiftUI

/// Side by side on the Mac; one above the other on iPhone, where a column is the whole width.
/// On the Mac this is exactly the `HStack` it replaced.
struct SideBySide<Content: View>: View {
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        HStack(alignment: alignment, spacing: spacing) { content }
        #else
        VStack(alignment: .leading, spacing: 24) { content }
        #endif
    }
}

/// A row of number tiles: one line on the Mac (exactly the `HStack` it replaced); wraps on iPhone.
struct TileRow<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        HStack(alignment: alignment, spacing: spacing) { content }
        #else
        FlowLayout(spacing: spacing) { content }
        #endif
    }
}

/// Page margins: roomy on the Mac, standard on iPhone.
enum PageMargin {
    #if os(macOS)
    static let horizontal: CGFloat = 36
    #else
    static let horizontal: CGFloat = 16
    #endif
}
