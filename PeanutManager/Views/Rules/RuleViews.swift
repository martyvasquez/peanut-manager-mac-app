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
                    Text(set.rules.filter(\.enabled).count == 1 ? "1 rule" : "\(set.rules.filter(\.enabled).count) rules")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Name", text: $ruleSet.name)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.weight(.bold))

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ruleSet.sortedRules) { rule in
                        RuleRow(rule: rule, focused: $focusedRule) { context.delete(rule) }
                    }
                    Button { addRule() } label: {
                        Label("New Rule", systemImage: "plus").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.checkbox)
            TextField("Rule", text: $rule.text, prompt: Text("Everyone plays at least 3 innings"), axis: .vertical)
                .textFieldStyle(.plain)
                .focused(focused, equals: rule.uid)
                .foregroundStyle(rule.enabled ? .primary : .tertiary)
            Spacer()
            CheckTag(check: Binding(get: { rule.check }, set: { rule.check = $0 }))
                .opacity(rule.check != nil || hovering ? 1 : 0)
            Button(action: onDelete) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .help("Delete")
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5) }
        .onHover { hovering = $0 }
    }
}

/// A rule with a check is verified by the app on every lineup; without one, it's left to the AI's judgment.
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
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(check?.summary.appending(" — checked by the app") ?? "Have the app check this rule")
    }
}
