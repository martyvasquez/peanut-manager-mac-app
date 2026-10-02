import SwiftUI
import SwiftData
import LineupKit

struct RuleSetsListView: View {
    @Environment(\.modelContext) private var context
    let team: Team
    @Binding var selection: RuleSet?

    var body: some View {
        List(selection: $selection) {
            ForEach(team.sortedRuleSets) { set in
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.name)
                    Text("\(set.rules.filter(\.enabled).count) active rules")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(set)
            }
        }
        .navigationTitle("Rules")
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .toolbar {
            Button("New Rule Set", systemImage: "plus") {
                let set = RuleSet(name: "New Rule Set")
                context.insert(set)
                set.team = team
                selection = set
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .contextMenu(forSelectionType: RuleSet.self) { sets in
            if let set = sets.first {
                Button("Delete", role: .destructive) {
                    if selection == set { selection = nil }
                    context.delete(set)
                }
            }
        }
    }
}

struct RuleSetEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var ruleSet: RuleSet
    @FocusState private var focusedRule: UUID?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $ruleSet.name)
            }
            Section {
                ForEach(ruleSet.sortedRules) { rule in
                    RuleRow(rule: rule, focused: $focusedRule) { delete(rule) }
                }
                .onMove(perform: move)
                Button("Add Rule", systemImage: "plus") { addRule() }
                    .buttonStyle(.borderless)
            } header: {
                Text("Rules, in priority order")
            } footer: {
                Text("Write rules the way you'd say them. The AI reads every rule as written. Rules with a code check (✓) are also verified by the app on every lineup; the others are left to the AI's judgment and labeled that way.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(ruleSet.name)
    }

    private func addRule() {
        let rule = Rule(text: "", order: (ruleSet.rules.map(\.order).max() ?? -1) + 1)
        context.insert(rule)
        rule.ruleSet = ruleSet
        focusedRule = rule.uid
    }

    private func delete(_ rule: Rule) {
        context.delete(rule)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var rules = ruleSet.sortedRules
        rules.move(fromOffsets: source, toOffset: destination)
        for (index, rule) in rules.enumerated() { rule.order = index }
    }
}

struct RuleRow: View {
    @Bindable var rule: Rule
    var focused: FocusState<UUID?>.Binding
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Rule", text: $rule.text, prompt: Text("e.g. Every player must play at least 3 innings in the field"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused(focused, equals: rule.uid)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                CheckPicker(check: Binding(get: { rule.check }, set: { rule.check = $0 }))
            }
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete rule")
        }
    }
}

/// "Understood as…" — attach a code check to a rule. (The AI rule interpreter will fill this in automatically later.)
struct CheckPicker: View {
    @Binding var check: RuleCheck?

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("AI judgment only") { check = nil }
                Divider()
                ForEach(RuleCheck.catalog, id: \.self) { template in
                    Button(template.summary.replacingOccurrences(of: "\(template.value)", with: "N")) {
                        check = .make(template.kind, check?.kind == template.kind ? check!.value : template.value)
                    }
                }
            } label: {
                if let check {
                    Label(check.summary, systemImage: "checkmark.seal")
                } else {
                    Label("AI judgment only", systemImage: "sparkles")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(check == nil ? Color.secondary : Color.accentColor)
            .fixedSize()

            if let current = check {
                Stepper("", value: Binding(get: { current.value }, set: { check = .make(current.kind, max(1, $0)) }), in: 1...9)
                    .labelsHidden()
                    .controlSize(.mini)
            }
        }
    }
}
