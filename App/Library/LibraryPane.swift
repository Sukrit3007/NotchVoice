import SwiftUI

/// A row in the sidebar. The cases *are* the sidebar, in order.
///
/// One enum for the whole window rather than one per section, because the
/// selection is one value and splitting it would mean two sources of truth for
/// "what is showing".
///
/// Named for their contents rather than for a category — "History", not
/// "Activity". A vague label makes the user open it to find out what is inside,
/// which is the opposite of what a sidebar is for.
enum LibraryPane: String, CaseIterable, Identifiable, Hashable {
    case history
    case dictionary
    case snippets
    case stats

    case general
    case dictation
    case speech
    case sound
    case permissions

    var id: Self { self }

    /// Which group it sits under. Settings live in the same window as the
    /// library on purpose — one place to learn — but they stay a separate
    /// section so the list does not read as eight equal things.
    enum Group: String, CaseIterable, Identifiable {
        case library = "Library"
        case settings = "Settings"

        var id: Self { self }

        var panes: [LibraryPane] {
            LibraryPane.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .history, .dictionary, .snippets, .stats: .library
        case .general, .dictation, .speech, .sound, .permissions: .settings
        }
    }

    var title: String {
        switch self {
        case .history: "History"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .stats: "Stats"
        case .general: "General"
        case .dictation: "Dictation"
        case .speech: "Speech"
        case .sound: "Sound"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock"
        case .dictionary: "character.book.closed"
        case .snippets: "text.append"
        case .stats: "chart.bar"
        case .general: "gearshape"
        case .dictation: "mic"
        case .speech: "waveform"
        case .sound: "speaker.wave.2"
        case .permissions: "lock.shield"
        }
    }
}
