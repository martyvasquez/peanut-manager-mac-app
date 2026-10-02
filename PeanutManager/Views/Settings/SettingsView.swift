import SwiftUI
import LineupAI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Models", systemImage: "cpu", value: "models") { ModelSettings() }
        }
        .scenePadding()
        .frame(width: 640, height: 640)
    }
}

struct GeneralSettings: View {
    @State private var apiKey = Keychain.apiKey
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                SecureField("OpenRouter Key", text: $apiKey, prompt: Text("sk-or-…"))
                    .onSubmit(save)
                HStack {
                    Button("Save") { save() }
                    Button("Test") { test() }.disabled(apiKey.isEmpty || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).foregroundStyle(.secondary) }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        Keychain.apiKey = apiKey
        testResult = "Saved"
    }

    private func test() {
        save()
        testing = true
        testResult = nil
        Task {
            do {
                try await OpenRouterClient(apiKey: apiKey).verifyKey()
                testResult = "Works"
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

/// Pick which models appear in the app, from OpenRouter's full live catalog.
struct ModelSettings: View {
    @State private var library = ModelLibrary.shared
    @State private var catalog: [OpenRouterClient.ModelInfo] = []
    @State private var loadError: String?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("In the App").font(.headline)
                List {
                    ForEach(library.models) { model in
                        HStack {
                            Image(systemName: library.selectedID == model.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(library.selectedID == model.id ? Color.accentColor : .secondary)
                                .onTapGesture { library.selectedID = model.id }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.name)
                                Text(model.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let info = catalog.first(where: { $0.id == model.id }) { PriceText(info: info) }
                            Button { library.remove(model.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(library.models.count == 1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { library.selectedID = model.id }
                    }
                    .onMove { library.models.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered)
                .frame(height: 240)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("All OpenRouter Models").font(.headline)
                TextField("Search", text: $search, prompt: Text("Search \(catalog.isEmpty ? "" : "\(catalog.count) ")models"))
                    .textFieldStyle(.roundedBorder)
                List {
                    if let loadError {
                        Text(loadError).foregroundStyle(.secondary)
                    } else if catalog.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                    }
                    if !search.isEmpty && search.contains("/") && !catalog.contains(where: { $0.id == search }) {
                        Button("Add \"\(search)\"") { library.add(SavedModel(id: search, name: search)) }
                    }
                    ForEach(results) { info in
                        let added = library.models.contains { $0.id == info.id }
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name)
                                Text(info.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            PriceText(info: info)
                            Button {
                                library.add(SavedModel(id: info.id, name: info.name))
                            } label: {
                                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(added ? Color.green : Color.accentColor)
                            .disabled(added)
                        }
                    }
                }
                .listStyle(.bordered)
            }
        }
        .task { await load() }
    }

    private var results: [OpenRouterClient.ModelInfo] {
        let terms = search.lowercased().split(separator: " ")
        let filtered = terms.isEmpty ? catalog : catalog.filter { info in
            let haystack = (info.name + " " + info.id).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        return Array(filtered.prefix(200))
    }

    private func load() async {
        do {
            catalog = try await OpenRouterClient.models().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            loadError = "Couldn't load models: \(error.localizedDescription)"
        }
    }
}

/// "$0.10 · $0.20" per million input / output tokens.
struct PriceText: View {
    let info: OpenRouterClient.ModelInfo

    var body: some View {
        Text("\(price(info.inputPrice)) · \(price(info.outputPrice))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("Per million tokens, input · output")
    }

    private func price(_ value: Double?) -> String {
        guard let value else { return "–" }
        if value == 0 { return "Free" }
        return value < 1 ? String(format: "$%.2f", value) : String(format: "$%.1f", value)
    }
}
