import SwiftUI
import SwiftData

/// Everything the app has heard, newest first.
///
/// The search field lives here and the list is a child, because a `@Query`'s
/// predicate is fixed at init — filtering has to happen in the store rather than
/// by loading every row and sifting it in the view.
@MainActor
struct HistoryPane: View {
    @State private var search = ""

    var body: some View {
        HistoryList(search: search)
            .searchable(text: $search, prompt: "Search transcripts")
    }
}

@MainActor
private struct HistoryList: View {
    @Environment(\.modelContext) private var context
    @Query private var captures: [Capture]

    private let search: String
    @State private var confirmingClearAll = false

    init(search: String) {
        self.search = search
        let predicate: Predicate<Capture> =
            search.isEmpty
            ? #Predicate { !$0.isArchived }
            : #Predicate { !$0.isArchived && $0.text.localizedStandardContains(search) }
        _captures = Query(filter: predicate, sort: \Capture.createdAt, order: .reverse)
    }

    var body: some View {
        Group {
            if captures.isEmpty {
                empty
            } else {
                list
            }
        }
        .toolbar {
            if !captures.isEmpty {
                Button("Clear History", systemImage: "trash") {
                    confirmingClearAll = true
                }
            }
        }
        // A confirmation, because this is destructive and there is no undo.
        // Reserved for exactly that — asking on every ordinary action trains
        // people to click through the one that matters.
        .confirmationDialog(
            "Delete every transcript?",
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive, action: clearAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your custom words and snippets are kept. This cannot be undone.")
        }
    }

    private var list: some View {
        List {
            ForEach(days, id: \.day) { group in
                Section(Self.dayLabel(group.day)) {
                    ForEach(group.captures) { capture in
                        CaptureRow(capture: capture)
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { copy(capture) }
                                Button("Archive", systemImage: "archivebox") {
                                    capture.isArchived = true
                                }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    context.delete(capture)
                                }
                            }
                    }
                }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(
                search.isEmpty ? "Nothing dictated yet" : "No matches",
                systemImage: search.isEmpty ? "waveform" : "magnifyingglass"
            )
        } description: {
            Text(
                search.isEmpty
                    ? "Hold your dictation key and say something. It will show up here."
                    : "No transcript contains “\(search)”."
            )
        }
    }

    // MARK: - Grouping

    private struct Day {
        let day: Date
        let captures: [Capture]
    }

    /// Grouped in the view rather than the query: SwiftData has no "group by",
    /// and the rows are already loaded and sorted by the time they get here.
    private var days: [Day] {
        Dictionary(grouping: captures) {
            Calendar.current.startOfDay(for: $0.createdAt)
        }
        .sorted { $0.key > $1.key }
        .map { Day(day: $0.key, captures: $0.value) }
    }

    /// "Today" and "Yesterday" rather than a date, because that is how someone
    /// looking for what they just dictated thinks about it.
    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Actions

    private func copy(_ capture: Capture) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(capture.text, forType: .string)
    }

    private func clearAll() {
        // Only what is on screen. Deleting archived rows too would make "Clear
        // History" quietly wider than the list it sits above.
        for capture in captures { context.delete(capture) }
    }
}
