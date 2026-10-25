import SwiftUI
import SwiftData
import LineupKit

/// The team's rule sets (League, Tournament…). A game picks one.
struct RuleSetsList: View {
    @Environment(\.modelContext) private var context
    let team: Team
    @State private var path: [RuleSet] = []
    @State private var deleting: RuleSet?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(team.sortedRuleSets) { set in
                    let count = set.rules.filter(\.enabled).count
                    NavigationLink(value: set) {
                        LabeledContent(set.name.isEmpty ? "Rule Set" : set.name, value: count == 1 ? "1 rule" : "\(count) rules")
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = set }
                    }
                }
            }
            .navigationTitle("Rules")
            .navigationDestination(for: RuleSet.self) { RuleSetEditor(ruleSet: $0) }
            .overlay {
                if team.ruleSets.isEmpty {
                    ContentUnavailableView {
                        Label("No Rules", systemImage: "list.bullet.clipboard")
                    } actions: {
                        Button("New Rule Set") { addSet() }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Rule Set", systemImage: "plus") { addSet() }
                }
            }
            #if DEBUG
            // `-PMRuleSet YES` opens the first rule set.
            .onAppear {
                if UserDefaults.standard.bool(forKey: "PMRuleSet"), let first = team.sortedRuleSets.first { path = [first] }
            }
            #endif
            .confirmationDialog("Delete \(deleting?.name ?? "this rule set")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Rule Set", role: .destructive) {
                    if let deleting { context.delete(deleting) }
                    deleting = nil
                }
            } message: {
                Text("Games that use it will have no rules.")
            }
        }
    }

    private func addSet() {
        let set = RuleSet(name: "New Rule Set")
        context.insert(set)
        set.team = team
        path.append(set)
    }
}

/// A rule set's rules, in plain language. A rule with a check is verified by the app on every lineup; without one,
/// it's left to the AI's judgment (and is a reminder without AI). Tap the circle to turn a rule off for now.
struct RuleSetEditor: View {
    @Environment(\.modelContext) private var context
    @Bindable var ruleSet: RuleSet
    @FocusState private var focusedRule: UUID?

    var body: some View {
        List {
            Section {
                TextField("Name", text: $ruleSet.name)
                    .font(.title3.weight(.semibold))
            }
            Section {
                ForEach(ruleSet.sortedRules) { rule in
                    RuleRow(rule: rule, focused: $focusedRule)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { context.delete(rule) }
                        }
                }
                Button("New Rule", systemImage: "plus", action: addRule)
            } footer: {
                Text("\(Image(systemName: "checkmark.seal.fill")) The app checks it on every lineup.")
            }
        }
        .navigationTitle("Rule Set")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addRule() {
        let rule = Rule(text: "", order: (ruleSet.rules.map(\.order).max() ?? -1) + 1)
        context.insert(rule)
        rule.ruleSet = ruleSet
        focusedRule = rule.uid
    }
}

struct RuleRow: View {
    @Bindable var rule: Rule
    var focused: FocusState<UUID?>.Binding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { rule.enabled.toggle() } label: {
                Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(rule.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(rule.enabled ? "On" : "Off")
            TextField("Rule", text: $rule.text, prompt: Text("Everyone plays at least 3 innings"), axis: .vertical)
                .focused(focused, equals: rule.uid)
                .foregroundStyle(rule.enabled ? .primary : .tertiary)
                // The divider runs under the rule's text, not from the check badge.
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            CheckTag(check: Binding(get: { rule.check }, set: { rule.check = $0 }))
        }
    }
}

/// Whether the app checks this rule, and with what number. The same catalog as the Mac.
struct CheckTag: View {
    @Binding var check: RuleCheck?

    var body: some View {
        Menu {
            Section("Check With the App") {
                ForEach(RuleCheck.catalog, id: \.self) { template in
                    Toggle(template.summary.replacingOccurrences(of: "\(template.value)", with: "N"), isOn: Binding(
                        get: { check?.kind == template.kind },
                        set: { on in check = on ? .make(template.kind, template.value) : nil }
                    ))
                }
            }
            if let current = check {
                Picker("N", selection: Binding(get: { current.value }, set: { check = .make(current.kind, $0) })) {
                    ForEach(1...9, id: \.self) { Text("\($0)").tag($0) }
                }
                Divider()
                Button("Don't Check") { check = nil }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: check == nil ? "checkmark.seal" : "checkmark.seal.fill")
                if let check { Text("\(check.value)").monospacedDigit() }
            }
            .font(.callout)
            .foregroundStyle(check == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.green))
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(check.map { "Checked by the app: \($0.summary)" } ?? "Not checked by the app")
    }
}
