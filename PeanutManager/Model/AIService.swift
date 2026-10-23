import AppKit
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

    /// The model the coach picked; nil follows the default.
    var chosenModelID: String? {
        didSet { UserDefaults.standard.set(chosenModelID, forKey: Keys.choice) }
    }
    /// The newest Luna the account offers, remembered so the app starts on it before the list loads.
    private(set) var chatGPTDefaultID: String {
        didSet { UserDefaults.standard.set(chatGPTDefaultID, forKey: Keys.defaultModel) }
    }
    /// Claude Sonnet once a key is saved (adding one means the coach wants Claude), else the newest Luna.
    var defaultModelID: String { hasClaudeKey ? AnthropicClient.defaultModel : chatGPTDefaultID }
    /// The coach's pick while it can run (its service is connected); nil follows the default. Settings binds to this.
    var activeChoice: String? {
        get {
            guard let chosen = chosenModelID else { return nil }
            let runnable = AnthropicClient.isClaude(chosen) ? hasClaudeKey : (isSignedIn || !hasClaudeKey)
            return runnable ? chosen : nil
        }
        set { chosenModelID = newValue }
    }
    /// The model requests use.
    var modelID: String { activeChoice ?? defaultModelID }
    /// The thinking level the coach picked; nil uses the app's default.
    var reasoningEffort: String? {
        didSet { UserDefaults.standard.set(reasoningEffort, forKey: Keys.effort) }
    }

    private var session: ChatGPTSession?
    private var signInTask: Task<Void, Never>?
    private let auth = ChatGPTAuth()

    nonisolated private enum Keys {
        static let choice = "chatGPTModelChoice"
        static let defaultModel = "chatGPTDefaultModel"
        static let legacyModel = "chatGPTModel"
        static let effort = "chatGPTEffort"
        static let welcomed = "chatGPTWelcomed"
        static let vault = "chatgpt-session"
        static let host = "chatgpt-host-id"
        static let anthropic = "anthropic-api-key"
    }

    private init() {
        let defaults = UserDefaults.standard
        chatGPTDefaultID = defaults.string(forKey: Keys.defaultModel) ?? ChatGPTClient.defaultModel
        // Builds before the newest-Sol default stored every model as a choice; only a non-default one was picked on purpose.
        if let legacy = defaults.string(forKey: Keys.legacyModel) {
            defaults.removeObject(forKey: Keys.legacyModel)
            if legacy != "gpt-5.6-sol" { defaults.set(legacy, forKey: Keys.choice) }
        }
        chosenModelID = defaults.string(forKey: Keys.choice)
        reasoningEffort = defaults.string(forKey: Keys.effort)
        anthropicKey = Keychain.data(Keys.anthropic).flatMap { String(data: $0, encoding: .utf8) }
        #if DEBUG
        if DebugSupport.fakeClaudeKey { anthropicKey = "sk-ant-debug-0000" }
        if DebugSupport.noAI { anthropicKey = nil }
        if DebugSupport.signedOut || DebugSupport.noAI { return }
        #endif
        if let record = Self.loadRecord() {
            account = record.account
            if let tokens = record.tokens { adopt(record.account, tokens) }
        }
        // Pick up new or retired models before anything runs.
        if isSignedIn { Task { await loadModels() } }
    }

    // MARK: - Clients

    /// The client and model for the next request. Never fails here: a missing sign-in surfaces when the request runs.
    func client() -> (client: any LLMClient, model: String, effort: String?) {
        #if DEBUG
        if DebugSupport.fakeAI { return (FakeLLMClient(), modelID, effectiveEffort) }
        #endif
        if AnthropicClient.isClaude(modelID) {
            guard let anthropicKey else { return (UnavailableClient(), modelID, effectiveEffort) }
            return (AnthropicClient(apiKey: anthropicKey, effort: effectiveEffort), modelID, effectiveEffort)
        }
        guard let session else { return (UnavailableClient(), modelID, effectiveEffort) }
        return (ChatGPTClient(session: session, reasoningEffort: effectiveEffort), modelID, effectiveEffort)
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

    var currentModelID: String { modelID }

    /// Whether the next request runs on Claude (the coach's API key) rather than the ChatGPT plan.
    var usesClaude: Bool { AnthropicClient.isClaude(modelID) }

    /// Whether AI actions can run; while not, the app shows Sign in with ChatGPT in their place.
    var isReady: Bool {
        #if DEBUG
        if DebugSupport.fakeAI { return true }
        #endif
        return isSignedIn || hasClaudeKey
    }

    var currentModelName: String { displayName(for: currentModelID) }

    /// "GPT-5.6-Sol"; falls back to a name made from the ID.
    func displayName(for id: String) -> String {
        AnthropicClient.models.first { $0.id == id }?.name ?? chatGPTModels.first { $0.id == id }?.name ?? Self.fallbackName(id)
    }

    static func fallbackName(_ id: String) -> String {
        guard id.hasPrefix("gpt-") else { return id }
        return "GPT-" + id.dropFirst(4).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
    }

    var currentModel: ChatGPTClient.ModelInfo? { chatGPTModels.first { $0.id == modelID } }

    /// Reasoning levels for the selected model, cheapest first.
    var effortChoices: [String] { usesClaude ? AnthropicClient.efforts : currentModel?.efforts ?? ["low", "medium", "high"] }

    /// The app's default thinking level, where the model offers it.
    static let defaultEffort = "medium"

    /// What requests use: the coach's pick, else Medium, else the model's own default.
    var effectiveEffort: String? {
        reasoningEffort ?? (effortChoices.contains(Self.defaultEffort) ? Self.defaultEffort : nil)
    }

    /// "Medium", or the model's own default when it has no Medium.
    var defaultEffortName: String? {
        (effortChoices.contains(Self.defaultEffort) ? Self.defaultEffort : currentModel?.defaultEffort)?.capitalized
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
        // A pinned ChatGPT model can't run now; follow the default (Claude, if there's a key).
        if let chosen = chosenModelID, !AnthropicClient.isClaude(chosen) { chosenModelID = nil }
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
            if let preferred = ChatGPTClient.preferredModel(in: models.map(\.id)) { chatGPTDefaultID = preferred }
            // A picked model OpenAI retired: back to the default.
            if let chosen = chosenModelID, !AnthropicClient.isClaude(chosen), !models.isEmpty, !models.contains(where: { $0.id == chosen }) { chosenModelID = nil }
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
        Keychain.set(Data(key.utf8), for: Keys.anthropic)
        anthropicKey = key
        return true
    }

    func removeClaudeKey() {
        Keychain.set(nil, for: Keys.anthropic)
        anthropicKey = nil
        keyError = nil
        if let chosen = chosenModelID, AnthropicClient.isClaude(chosen) { chosenModelID = nil }
        if let effort = reasoningEffort, !effortChoices.contains(effort) { reasoningEffort = nil }
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
