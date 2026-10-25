import AuthenticationServices
import UIKit

/// Sign in with ChatGPT on iOS. OpenAI's page opens in a sheet over the app (not in Safari, which would send the
/// app to the background where it can't listen), and its redirect to 127.0.0.1 reaches `ChatGPTAuth`'s listener
/// in this app. The sheet closes once the sign-in finishes; closing it by hand cancels the sign-in.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebSignIn()

    private var session: ASWebAuthenticationSession?

    func open(_ url: URL) {
        close()
        // The callback scheme is never reached: the redirect goes to the loopback listener instead.
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("peanutmanager")) { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.session != nil else { return }
                self.session = nil
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    AIService.shared.cancelSignIn()
                }
            }
        }
        session.presentationContextProvider = self
        // Share Safari's cookies, so a coach already signed in to ChatGPT there isn't asked again.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    func close() {
        guard let session else { return }
        self.session = nil
        session.cancel()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
