import SwiftUI
import SwiftData

/// Words the speech model keeps getting wrong.
///
/// The phrase is edited in a sheet rather than inline. `phrase` is `.unique`,
/// and SwiftData resolves a uniqueness conflict by **upserting** — typing a word
/// that already exists would silently merge two rows rather than complain. The
/// sheet is where that gets checked before it can happen.
@MainActor
struct DictionaryPane: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DictionaryEntry.phrase) private var stored: [DictionaryEntry]

    /// Starred first, then alphabetical. Ordered here rather than in the query
    /// because a `SortDescriptor` on a `Bool` sorts false-first and reversing it
    /// would also reverse the alphabet.
    private var entries: [DictionaryEntry] {
        stored.sorted { ($0.isStarred ? 0 : 1, $0.phrase) < ($1.isStarred ? 0 : 1, $1.phrase) }
    }

    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    var body: some View {
        Group {
            if entries.isEmpty { empty } else { list }
        }
        .toolbar {
            Button("Add Word", systemImage: "plus") { isAdding = true }
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(existing: nil, taken: takenPhrases) { phrase, misheard in
                context.insert(DictionaryEntry(phrase: phrase, misheardAs: misheard))
            }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(existing: entry, taken: takenPhrases.subtracting([entry.phrase])) {
                phrase, misheard in
                entry.phrase = phrase
                entry.misheardAs = misheard
            }
        }
    }

    private var takenPhrases: Set<String> {
        Set(entries.map { $0.phrase.lowercased() })
    }

    private var list: some View {
        List {
            ForEach(entries) { entry in
                row(entry)
                    .contextMenu {
                        Button("Edit…", systemImage: "pencil") { editing = entry }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            context.delete(entry)
                        }
                    }
            }
        }
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                entry.isStarred.toggle()
            } label: {
                Image(systemName: entry.isStarred ? "star.fill" : "star")
                    // Wrapped because the two branches are different shape
                    // styles — `Color.yellow` and the hierarchical `.tertiary`
                    // — and a ternary needs one type.
                    .foregroundStyle(entry.isStarred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(entry.isStarred ? "Unpin" : "Pin to the top")
            .accessibilityLabel(entry.isStarred ? "Pinned" : "Not pinned")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.phrase)
                if let misheard = entry.misheardAs, !misheard.isEmpty {
                    // Stated as the rewrite it performs, not as a field name —
                    // "heard as X" leaves the direction ambiguous.
                    Text("“\(misheard)” becomes “\(entry.phrase)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.timesApplied > 0 {
                Text("\(entry.timesApplied)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Times this rewrite has fired")
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(count: 2) { editing = entry }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No custom words", systemImage: "character.book.closed")
        } description: {
            Text(
                "Add names and jargon the speech model keeps mishearing. "
                + "They are suggested to it before it transcribes, which is what fixes them."
            )
        } actions: {
            Button("Add Word") { isAdding = true }
        }
    }
}

/// Add or edit one entry, with the uniqueness check the list cannot do inline.
@MainActor
private struct DictionaryEditor: View {
    let existing: DictionaryEntry?
    let taken: Set<String>
    let onSave: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var misheardAs = ""

    private var trimmed: String { phrase.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { taken.contains(trimmed.lowercased()) }
    private var canSave: Bool { !trimmed.isEmpty && !isDuplicate }

    var body: some View {
        Form {
            Section {
                TextField("Word or phrase", text: $phrase)
                    .textFieldStyle(.roundedBorder)
            } footer: {
                // Inline, as it is typed — not on submit. A field that accepts
                // input and rejects it at the end wastes the effort in between.
                if isDuplicate {
                    Label("Already in your dictionary", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Text("Suggested to the speech model so it hears this correctly.")
                        .font(.caption)
                }
            }

            Section {
                TextField("Optional", text: $misheardAs)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Replace when it hears")
            } footer: {
                Text(
                    "A blunt fallback for when suggesting the word is not enough. "
                    + "It rewrites the text afterwards, so leave it empty unless you need it."
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") {
                    onSave(trimmed, misheardAs.isEmpty ? nil : misheardAs)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            phrase = existing?.phrase ?? ""
            misheardAs = existing?.misheardAs ?? ""
        }
    }
}
