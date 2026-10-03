import AppKit
import Foundation
import LineupKit
import LineupAI

enum AIServiceError: Error, LocalizedError {
    case signInNeeded

    var errorDescription: String? {
        switch self {
        case .signInNeeded: "Sign in with ChatGPT in Settings to make lineups and scouting reports."
        }
    }
}

/// The AI that makes lineups and assessments: the coach's ChatGPT plan, through Sign in with ChatGPT.
/// Owns the sign-in, the account's models, and the model choice. App-wide.
@Observable
final class AIService {
    static let shared = AIService()

    // MARK: ChatGPT state
    private(set) var account: ChatGPTAccount?
    private(set) var isSignedIn = false
    private(set) var planUsageGranted = false
    private(set) var isSigningIn = false
    var signInError: String?
    private(set) var chatGPTModels: [ChatGPTClient.ModelInfo] = []
    private(set) var modelsError: String?
    /// The one-time "You're using your ChatGPT plan" message.
    var showWelcome = false

    var chatGPTModelID: String {
        didSet { UserDefaults.standard.set(chatGPTModelID, forKey: Keys.model) }
    }
    /// nil uses the model's default.
    var reasoningEffort: String? {
        didSet { UserDefaults.standard.set(reasoningEffort, forKey: Keys.effort) }
    }

    private var session: ChatGPTSession?
    private var signInTask: Task<Void, Never>?
    private let auth = ChatGPTAuth()

    nonisolated private enum Keys {
        static let model = "chatGPTModel"
        static let effort = "chatGPTEffort"
        static let welcomed = "chatGPTWelcomed"
        static let vault = "chatgpt-session"
        static let host = "chatgpt-host-id"
    }

    private init() {
        let defaults = UserDefaults.standard
        chatGPTModelID = defaults.string(forKey: Keys.model) ?? ChatGPTClient.defaultModel
        reasoningEffort = defaults.string(forKey: Keys.effort)
        if let record = Self.loadRecord() {
            account = record.account
            if let tokens = record.tokens { adopt(record.account, tokens) }
        }
    }

    // MARK: - Clients

    /// The client and model for the next request. Never fails here: a missing sign-in surfaces when the request runs.
    func client() -> (client: any LLMClient, model: String) {
        #if DEBUG
        if DebugSupport.fakeAI { return (FakeLLMClient(), chatGPTModelID) }
        #endif
        guard let session else { return (UnavailableClient(), chatGPTModelID) }
        return (ChatGPTClient(session: session, reasoningEffort: reasoningEffort), chatGPTModelID)
    }

    var currentModelID: String { chatGPTModelID }

    var currentModelName: String { displayName(for: currentModelID) }

    /// "GPT-5.6-Sol"; falls back to a name made from the ID.
    func displayName(for id: String) -> String {
        chatGPTModels.first { $0.id == id }?.name ?? Self.fallbackName(id)
    }

    static func fallbackName(_ id: String) -> String {
        guard id.hasPrefix("gpt-") else { return id }
        return "GPT-" + id.dropFirst(4).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
    }

    var currentModel: ChatGPTClient.ModelInfo? { chatGPTModels.first { $0.id == chatGPTModelID } }

    /// Reasoning levels for the selected ChatGPT model, cheapest first.
    var effortChoices: [String] { currentModel?.efforts ?? ["low", "medium", "high"] }

    // MARK: - Sign in / out

    /// Opens the browser for Sign in with ChatGPT. `askConsent` re-shows the permission screen (turning plan use back on).
    func signIn(askConsent: Bool = false) {
        guard signInTask == nil else { return }
        signInError = nil
        isSigningIn = true
        let previous = account
        let hint = Self.loadRecord()?.tokens?.idToken
        signInTask = Task {
            defer { isSigningIn = false; signInTask = nil }
            do {
                let (account, tokens) = try await auth.signIn(hostID: Self.hostID(), account: previous, idTokenHint: hint, askConsent: askConsent) { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                Self.saveRecord(Record(account: account, tokens: tokens))
                adopt(account, tokens)
                NSApp.activate()
                if tokens.planUsageGranted && !UserDefaults.standard.bool(forKey: Keys.welcomed) {
                    UserDefaults.standard.set(true, forKey: Keys.welcomed)
                    showWelcome = true
                }
                await loadModels()
            } catch is CancellationError {
            } catch {
                signInError = error.localizedDescription
                NSApp.activate()
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// Ends the session on OpenAI's side, then forgets the tokens. Keeps the registration so the next sign-in reuses it.
    func signOut() {
        let record = Self.loadRecord()
        session = nil
        isSignedIn = false
        planUsageGranted = false
        chatGPTModels = []
        if let account { Self.saveRecord(Record(account: account, tokens: nil)) }
        guard let record, let tokens = record.tokens else { return }
        Task {
            do {
                try await auth.revoke(tokens, account: record.account)
            } catch {
                signInError = "Signed out here, but ChatGPT didn't confirm it. You can disconnect Peanut Manager in ChatGPT settings."
            }
        }
    }

    /// Forget the saved registration so the next sign-in can pick any ChatGPT account.
    func useDifferentAccount() {
        signOut()
        account = nil
        Self.saveRecord(nil)
        signIn()
    }

    func loadModels() async {
        guard let session else { return }
        do {
            let models = try await ChatGPTClient(session: session).models()
            chatGPTModels = models
            modelsError = nil
            if !models.isEmpty && !models.contains(where: { $0.id == chatGPTModelID }) {
                chatGPTModelID = models.first { $0.id == ChatGPTClient.defaultModel }?.id ?? models[0].id
            }
            if let effort = reasoningEffort, !effortChoices.contains(effort) { reasoningEffort = nil }
        } catch {
            modelsError = error.localizedDescription
        }
    }

    private func adopt(_ account: ChatGPTAccount, _ tokens: ChatGPTTokens) {
        self.account = account
        isSignedIn = true
        planUsageGranted = tokens.planUsageGranted
        session = ChatGPTSession(account: account, tokens: tokens) { tokens in
            // Called off the main actor with each refreshed token set, or nil once the session can't be renewed.
            Self.saveTokens(tokens, for: account)
            if tokens == nil { Task { @MainActor in AIService.shared.sessionEnded() } }
        }
    }

    private func sessionEnded() {
        session = nil
        isSignedIn = false
        planUsageGranted = false
    }

    // MARK: - Keychain

    nonisolated struct Record: Codable {
        var account: ChatGPTAccount
        var tokens: ChatGPTTokens?
    }

    nonisolated private static func loadRecord() -> Record? {
        Keychain.data(Keys.vault).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    nonisolated private static func saveRecord(_ record: Record?) {
        Keychain.set(record.flatMap { try? JSONEncoder().encode($0) }, for: Keys.vault)
    }

    nonisolated private static func saveTokens(_ tokens: ChatGPTTokens?, for account: ChatGPTAccount) {
        saveRecord(Record(account: account, tokens: tokens))
    }

    /// This install's opaque host ID, made once and kept for good.
    nonisolated private static func hostID() -> String {
        if let data = Keychain.data(Keys.host), let id = String(data: data, encoding: .utf8) { return id }
        let id = ChatGPTAuth.newHostID()
        Keychain.set(Data(id.utf8), for: Keys.host)
        return id
    }

    // MARK: - Errors

    /// Problems a retry can't fix.
    static func isFatal(_ error: Error) -> Bool {
        if error is AIServiceError { return true }
        if let error = error as? ChatGPTAuth.AuthError { return error == .signInAgain }
        return (error as? ChatGPTClient.ClientError)?.isFatal ?? false
    }

    /// Problems that usually clear up on their own: timeouts, dropped connections, rate limits, server errors.
    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        return (error as? ChatGPTClient.ClientError)?.isTransient ?? false
    }

    static func isUsageLimit(_ error: Error) -> Bool {
        (error as? ChatGPTClient.ClientError) == .usageLimit
    }
}

/// Stands in for ChatGPT before sign-in, so the request fails with a clear message.
private struct UnavailableClient: LLMClient {
    func complete(_ request: LLMRequest) async throws -> LLMResponse { throw AIServiceError.signInNeeded }
}
