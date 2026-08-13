import SwiftUI
import SwiftData

/// Short phrases that expand into longer ones.
///
/// Same uniqueness trap as the dictionary — `trigger` is `.unique` and SwiftData
/// upserts on conflict — so editing happens in a sheet that checks first.
@MainActor
struct SnippetsPane: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Snippet.trigger) private var snippets: [Snippet]

    @State private var editing: Snippet?
    @State private var isAdding = false

    var body: some View {
        Group {
            if snippets.isEmpty { empty } else { list }
        }
        .toolbar {
            Button("Add Snippet", systemImage: "plus") { isAdding = true }
        }
        .sheet(isPresented: $isAdding) {
            SnippetEditor(existing: nil, taken: takenTriggers) { trigger, expansion in
                context.insert(Snippet(trigger: trigger, expansion: expansion))
            }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(
                existing: snippet,
                taken: takenTriggers.subtracting([snippet.trigger.lowercased()])
            ) { trigger, expansion in
                snippet.trigger = trigger
                snippet.expansion = expansion
            }
        }
    }

    private var takenTriggers: Set<String> {
        Set(snippets.map { $0.trigger.lowercased() })
    }

    private var list: some View {
        List {
            ForEach(snippets) { snippet in
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.trigger)
                    Text(snippet.expansion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
                .contentShape(.rect)
                .onTapGesture(count: 2) { editing = snippet }
                .contextMenu {
                    Button("Edit…", systemImage: "pencil") { editing = snippet }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        context.delete(snippet)
                    }
                }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No snippets", systemImage: "text.append")
        } description: {
            Text("Say a short phrase and have something longer pasted instead — an address, a signature, a block of boilerplate.")
        } actions: {
            Button("Add Snippet") { isAdding = true }
        }
    }
}

@MainActor
private struct SnippetEditor: View {
    let existing: Snippet?
    let taken: Set<String>
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trigger = ""
    @State private var expansion = ""

    private var trimmedTrigger: String {
        trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isDuplicate: Bool { taken.contains(trimmedTrigger.lowercased()) }
    private var canSave: Bool {
        !trimmedTrigger.isEmpty && !expansion.isEmpty && !isDuplicate
    }

    var body: some View {
        Form {
            Section {
                TextField("What you say", text: $trigger)
                    .textFieldStyle(.roundedBorder)
            } footer: {
                if isDuplicate {
                    Label("Already a snippet", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section("What gets pasted") {
                TextEditor(text: $expansion)
                    .font(.body)
                    .frame(minHeight: 90)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") {
                    onSave(trimmedTrigger, expansion)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            trigger = existing?.trigger ?? ""
            expansion = existing?.expansion ?? ""
        }
    }
}
