import Foundation
import LineupAI

/// A model the coach has pinned for use in the app.
nonisolated struct SavedModel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

/// The models shown in the app's model menu, and which one makes lineups. Stored in UserDefaults.
@Observable
final class ModelLibrary {
    static let shared = ModelLibrary()

    static let starters: [SavedModel] = [
        SavedModel(id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5"),
        SavedModel(id: "anthropic/claude-opus-5.5", name: "Claude Opus 5.5"),
        SavedModel(id: "openai/gpt-5.6-sol", name: "GPT-5.6 Sol"),
        SavedModel(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash"),
        SavedModel(id: "meta/muse-spark-1.3-contributor", name: "Muse Spark 1.3 Contributor"),
    ]

    private static let savedKey = "savedModels"

    var models: [SavedModel] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(models), forKey: Self.savedKey) }
    }

    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: AppSettings.lineupModelKey) }
    }

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.savedKey).flatMap { try? JSONDecoder().decode([SavedModel].self, from: $0) }
        var models = stored ?? Self.starters
        let selected = UserDefaults.standard.string(forKey: AppSettings.lineupModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? OpenRouterClient.defaultLineupModel
        if !models.contains(where: { $0.id == selected }) { models.append(SavedModel(id: selected, name: selected)) }
        self.models = models
        self.selectedID = selected
    }

    var selected: SavedModel { models.first { $0.id == selectedID } ?? SavedModel(id: selectedID, name: selectedID) }

    func add(_ model: SavedModel) {
        if !models.contains(where: { $0.id == model.id }) { models.append(model) }
    }

    func remove(_ id: String) {
        models.removeAll { $0.id == id }
        if selectedID == id { selectedID = models.first?.id ?? OpenRouterClient.defaultLineupModel }
    }
}
