import SwiftUI

/// PLACEHOLDER (Task 11). Task 12 replaces this body with the real island.
///
/// It exists now only so `IslandWindowController` compiles: the plan's Task 11
/// hosts `IslandView` but does not create it until Task 12, which would mean
/// committing code that cannot build and leaving this task unverifiable.
///
/// Deliberately draws nothing. A visible placeholder would be a coloured strip
/// pinned above the menu bar across the full width of the screen, and there is
/// no way to dismiss it — the window ignores mouse events by design.
struct IslandView: View {
    @ObservedObject var coordinator: DictationCoordinator
    let notchSize: CGSize?

    init(coordinator: DictationCoordinator, notchSize: CGSize?) {
        self.coordinator = coordinator
        self.notchSize = notchSize
    }

    var body: some View {
        Color.clear
    }
}
