#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import LineupKit
import LineupAI

enum AIServiceError: Error, LocalizedError {
    case signInNeeded

    var errorDescription: String? {
        switch self {
        case .signInNeeded: "Sign in with ChatGPT or add a Claude API key in Settings to make lineups and scouting reports."
        }
    }
}

/// The AI that makes lineups and assessments: the coach's ChatGPT plan through Sign in with ChatGPT, or Claude
/// through the coach's own Anthropic API key. Owns the sign-in, the key, the models, and the model choice. App-wide.
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

    // MARK: Claude state
    /// The coach's Anthropic API key, from the keychain.
    private(set) var anthropicKey: String?
    private(set) var isCheckingKey = false
    var keyError: String?
    var hasClaudeKey: Bool { anthropicKey != nil }

    // MARK: The model
    // Coaches don't pick models: rule adherence is the promise, so the app runs only models that passed the
    // blind rule-following evals, pinned to exact versions, at the thinking level they were tested at. A new
    // model ships only after it wins an eval (`-PMRunEval`, `-PMModel`); then its ID changes here.

    /// Claude, with the coach's API key: Sonnet 5.5 led the Oct 20 blind evals.
    static let claudeModel = AnthropicClient.defaultModel
    /// ChatGPT, on the coach's plan: Luna 5.6 kept every lock in the Oct 3 eval.
    static let chatGPTModel = ChatGPTClient.defaultModel
    /// The thinking level the evals ran at.
    static let effort = "medium"

    /// The model requests use: the connected service's pinned model.
    var modelID: String {
        #if DEBUG
        if let model = DebugSupport.model { return model }
        #endif
        return hasClaudeKey ? Self.claudeModel : chatGPTModelID
    }

    /// Luna 5.6, or, only if OpenAI has retired it from the account, the newest Luna it offers.
    private var chatGPTModelID: String {
        let ids = chatGPTModels.map(\.id)
        guard !ids.isEmpty, !ids.contains(Self.chatGPTModel) else { return Self.chatGPTModel }
        return ChatGPTClient.preferredModel(in: ids) ?? Self.chatGPTModel
    }

    private var session: ChatGPTSession?
    private var signInTask: Task<Void, Never>?
    private let auth = ChatGPTAuth()

    nonisolated private enum Keys {
        /// Model and thinking choices from before models were pinned; cleared on launch.
        static let retired = ["chatGPTModelChoice", "chatGPTDefaultModel", "chatGPTModel", "chatGPTEffort", "aiProvider"]
        static let welcomed = "chatGPTWelcomed"
        static let vault = "chatgpt-session"
        static let host = "chatgpt-host-id"
        static let anthropic = "anthropic-api-key"
        static let consent = "aiSharingAllowed."
    }

    private init() {
        let defaults = UserDefaults.standard
        #if DEBUG
        if !DebugSupport.noAI && !DebugSupport.fakeAI { Keys.retired.forEach(defaults.removeObject) }
        #else
        Keys.retired.forEach(defaults.removeObject)
        #endif
        #if DEBUG
        // Test runs that don't use the real AI never touch the keychain, so they never ask for the password.
        if DebugSupport.fakeClaudeKey && !DebugSupport.noAI { anthropicKey = "sk-ant-debug-0000" }
        if DebugSupport.noAI || DebugSupport.fakeAI { return }
        #endif
        // Secrets saved by older builds move out of the login keychain, which asked for the password per item:
        // the Claude key to iCloud Keychain (it follows the coach), the ChatGPT sign-in to this device only.
        Keychain.move(Keys.anthropic, synced: CloudSync.enabled)
        Keychain.move(Keys.vault, synced: false)
        Keychain.move(Keys.host, synced: false)
        if anthropicKey == nil {
            anthropicKey = Keychain.data(Keys.anthropic).flatMap { String(data: $0, encoding: .utf8) }
        }
        #if DEBUG
        if DebugSupport.signedOut { return }
        #endif
        if let record = Self.loadRecord() {
            account = record.account
            if let tokens = record.tokens { adopt(record.account, tokens) }
        }
        // One AI at a time. Setups from before that rule keep Claude (the first choice, and a key is harder to
        // enter again than signing back in) and sign out of ChatGPT.
        var keepsBoth = false
        #if DEBUG
        keepsBoth = DebugSupport.fakeClaudeKey  // an in-memory test key must never sign out the real account
        #endif
        if isSignedIn && hasClaudeKey && !keepsBoth { signOut() }
        // Learn whether OpenAI still offers the pinned Luna before anything runs.
        if isSignedIn { Task { await loadModels() } }
    }

    // MARK: - Clients

    /// The client and model for the next request. Never fails here: a missing sign-in surfaces when the request runs.
    func client() -> (client: any LLMClient, model: String, effort: String?) {
        #if DEBUG
        if DebugSupport.fakeAI { return (FakeLLMClient(), modelID, Self.effort) }
        #endif
        if AnthropicClient.isClaude(modelID) {
            guard let anthropicKey else { return (UnavailableClient(), modelID, Self.effort) }
            return (AnthropicClient(apiKey: anthropicKey, effort: Self.effort), modelID, Self.effort)
        }
        guard let session else { return (UnavailableClient(), modelID, Self.effort) }
        return (ChatGPTClient(session: session, reasoningEffort: Self.effort), modelID, Self.effort)
    }

    /// "Luna · Medium": the model and, when known, its thinking level.
    func displayName(for id: String, effort: String?) -> String {
        displayName(for: id) + (effort.map { " · \($0.capitalized)" } ?? "")
    }

    #if DEBUG
    /// A client at a fixed thinking level, whatever the coach picked. For the model eval.
    func client(effort: String?) -> any LLMClient {
        if DebugSupport.fakeAI { return FakeLLMClient() }
        guard let session else { return UnavailableClient() }
        return ChatGPTClient(session: session, reasoningEffort: effort)
    }
    #endif

    /// Whether the next request runs on Claude (the coach's API key) rather than the ChatGPT plan.
    var usesClaude: Bool { AnthropicClient.isClaude(modelID) }

    /// Whether AI actions can run; while not, the app shows Sign in with ChatGPT in their place.
    var isReady: Bool {
        #if DEBUG
        if DebugSupport.fakeAI { return true }
        #endif
        return isSignedIn || hasClaudeKey
    }

    /// "Claude Sonnet 5.5": what the coach sees, never chooses.
    var currentModelName: String { displayName(for: modelID) }

    /// "GPT-5.6-Sol"; falls back to a name made from the ID.
    func displayName(for id: String) -> String {
        AnthropicClient.models.first { $0.id == id }?.name ?? chatGPTModels.first { $0.id == id }?.name ?? Self.fallbackName(id)
    }

    static func fallbackName(_ id: String) -> String {
        guard id.hasPrefix("gpt-") else { return id }
        return "GPT-" + id.dropFirst(4).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
    }

    // MARK: - Sharing with the AI company

    /// The company a request goes to, which the coach agrees to once before anything about the team is sent.
    enum Provider: String {
        case openAI, anthropic

        var company: String { self == .openAI ? "OpenAI" : "Anthropic" }
        var product: String { self == .openAI ? "ChatGPT" : "Claude" }
        var privacyPolicy: URL {
            URL(string: self == .openAI ? "https://openai.com/policies/privacy-policy" : "https://www.anthropic.com/legal/privacy")!
        }
    }

    /// An AI action waiting for the coach to agree to share with `provider`.
    struct ConsentRequest: Identifiable {
        let id = UUID()
        let provider: Provider
        let proceed: () -> Void
    }

    /// Shown as a sheet over the main window; the action runs only after Allow.
    var consentRequest: ConsentRequest?
    /// Allowed and waiting for the sheet to finish closing, so the action never starts while a sheet is in motion.
    @ObservationIgnored private var allowed: ConsentRequest?

    /// Where the next request goes; nil when nothing leaves the Mac (the debug fake AI).
    var provider: Provider? {
        #if DEBUG
        if DebugSupport.fakeAI { return DebugSupport.autoAllow ? .openAI : nil }
        #endif
        return usesClaude ? .anthropic : .openAI
    }

    /// Whether the next AI action must ask first.
    var needsConsent: Bool {
        guard let provider else { return false }
        #if DEBUG
        if DebugSupport.autoAllow { return !testAllowed }
        #endif
        return !UserDefaults.standard.bool(forKey: Keys.consent + provider.rawValue)
    }

    #if DEBUG
    /// `-PMAutoAllow` remembers its Allow for this run only, so a test never grants consent in the coach's settings.
    @ObservationIgnored private var testAllowed = false
    #endif

    /// Asks before `action` runs; the coach's Allow is remembered for that company.
    func askConsent(then action: @escaping () -> Void) {
        guard let provider else { return action() }
        consentRequest = ConsentRequest(provider: provider, proceed: action)
    }

    func allow(_ request: ConsentRequest) {
        #if DEBUG
        if DebugSupport.autoAllow { testAllowed = true; allowed = request; consentRequest = nil; return }
        #endif
        UserDefaults.standard.set(true, forKey: Keys.consent + request.provider.rawValue)
        allowed = request
        consentRequest = nil
    }

    /// The consent sheet has closed: run the action the coach allowed (Not Now runs nothing).
    func consentSheetClosed() {
        let request = allowed
        allowed = nil
        request?.proceed()
    }

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
                    #if os(macOS)
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                    #else
                    await MainActor.run { UIApplication.shared.open(url) }
                    #endif
                }
                Self.saveRecord(Record(account: account, tokens: tokens))
                adopt(account, tokens)
                // One AI at a time: ChatGPT replaces Claude only now that it works.
                if hasClaudeKey { removeClaudeKey() }
                #if os(macOS)
                NSApp.activate()
                #endif
                if tokens.planUsageGranted && !UserDefaults.standard.bool(forKey: Keys.welcomed) {
                    UserDefaults.standard.set(true, forKey: Keys.welcomed)
                    showWelcome = true
                }
                await loadModels()
            } catch is CancellationError {
            } catch {
                signInError = error.localizedDescription
                #if os(macOS)
                NSApp.activate()
                #endif
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

    // MARK: - Claude key

    /// Checks the key with Anthropic, then keeps it in the keychain. Returns whether it was saved.
    @discardableResult
    func saveClaudeKey(_ raw: String) async -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isCheckingKey else { return false }
        keyError = nil
        isCheckingKey = true
        defer { isCheckingKey = false }
        do {
            try await AnthropicClient(apiKey: key).checkKey()
        } catch {
            keyError = error.localizedDescription
            return false
        }
        Keychain.set(Data(key.utf8), for: Keys.anthropic, synced: true)
        anthropicKey = key
        // One AI at a time: Claude replaces ChatGPT only now that the key checked out.
        if isSignedIn { signOut() }
        return true
    }

    func removeClaudeKey() {
        Keychain.set(nil, for: Keys.anthropic)
        anthropicKey = nil
        keyError = nil
    }

    /// "sk-ant-…QAA": enough to recognize the key, never the key.
    var maskedClaudeKey: String? {
        anthropicKey.map { "sk-ant-…" + $0.suffix(4) }
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
        if let error = error as? AnthropicClient.ClientError { return error.isFatal }
        return (error as? ChatGPTClient.ClientError)?.isFatal ?? false
    }

    /// Problems that usually clear up on their own: timeouts, dropped connections, rate limits, server errors.
    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let error = error as? AnthropicClient.ClientError { return error.isTransient }
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
