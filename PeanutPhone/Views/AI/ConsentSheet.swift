import SwiftUI

/// Nothing about the team leaves the phone until the coach agrees to share it with the AI company.
/// The Mac's wording, word for word.
struct ConsentSheet: View {
    let request: AIService.ConsentRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Share Your Team with \(request.provider.company)?")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("AI suggestions come from \(request.provider.company)’s \(request.provider.product). When you use them, Peanut Manager sends \(request.provider.company) your players’ names, stats, ratings and notes, and your notes for the game.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link("\(request.provider.company) Privacy Policy", destination: request.provider.privacyPolicy)
                .font(.callout)
            Spacer(minLength: 0)
            Button { AIService.shared.allow(request) } label: {
                Text("Allow").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            Button("Not Now") { dismiss() }
                .frame(minHeight: 44)
        }
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 12)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}
