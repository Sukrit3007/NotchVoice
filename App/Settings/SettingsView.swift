import SwiftUI

/// Settings: a sidebar of panes over the app's preferences and permissions.
///
/// Stock `NavigationSplitView` and `Form(.grouped)`, deliberately. The previous
/// window built its rows out of Liquid Glass over an opaque
/// `windowBackgroundColor` — glass is a *refractive* material, so with a solid
/// colour behind it there was nothing to refract and the effect rendered as a
/// flat tint for the cost of a material. Glass belongs on floating chrome over
/// content; a settings window is where familiarity beats novelty. The island
/// stays this app's signature.
@MainActor
struct SettingsView: View {
    var model: SettingsModel
    var coordinator: DictationCoordinator

    var body: some View {
        NavigationSplitView {
            List(selection: paneSelection) {
                ForEach(SettingsPane.allCases) { pane in
                    row(for: pane).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
        } detail: {
            detail
                .navigationTitle(model.pane.title)
        }
    }

    /// `List` wants an optional selection; the model's is not, because a detail
    /// pane always has to be showing something. Deselecting keeps the current
    /// pane rather than emptying the window.
    private var paneSelection: Binding<SettingsPane?> {
        Binding(
            get: { model.pane },
            set: { selected in if let selected { model.pane = selected } }
        )
    }

    @ViewBuilder
    private func row(for pane: SettingsPane) -> some View {
        HStack(spacing: 0) {
            Label(pane.title, systemImage: pane.symbol)
            // The one thing a sidebar must be able to say without being
            // clicked. The menu bar glyph and the island's resting tint carry
            // the same warning, but neither is visible with this window open
            // and in front of them.
            if pane == .permissions, !model.status.canDictate {
                Spacer(minLength: 8)
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("A required permission is missing")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.pane {
        case .general:
            GeneralPane()
        case .dictation:
            DictationPane(model: model, coordinator: coordinator)
        case .permissions:
            PermissionsPane(model: model)
        case .sound:
            SoundPane()
        }
    }
}
