import SwiftUI

/// The Mac's `.link` button style, which iOS doesn't have, as a plain tappable link in the accent color,
/// so the shared Insights views compile unchanged.
struct LinkButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.borderless)
    }
}

extension PrimitiveButtonStyle where Self == LinkButtonStyle {
    static var link: LinkButtonStyle { LinkButtonStyle() }
}
