import SwiftUI

/// The app's one window: what it has heard, what it knows, and how it behaves.
///
/// Stock `NavigationSplitView` and `Form(.grouped)`, deliberately. An earlier
/// version of the settings window built its rows out of Liquid Glass over an
/// opaque background — glass is a *refractive* material, so with a solid colour
/// behind it there is nothing to refract and it renders as a flat tint for the
/// cost of a material. Glass belongs on floating chrome over content; the island
/// is where this app spends that budget.
@MainActor
struct LibraryView: View {
    @Bindable var model: SettingsModel
    let coordinator: DictationCoordinator
    let isHistoryEphemeral: Bool

    init(
        model: SettingsModel,
        coordinator: DictationCoordinator,
        isHistoryEphemeral: Bool = false
    ) {
        self.model = model
        self.coordinator = coordinator
        self.isHistoryEphemeral = isHistoryEphemeral
    }

    var body: some View {
        VStack(spacing: 0) {
            if isHistoryEphemeral {
                Label(
                    "History is temporary for this launch. Dictation still works, but new captures will not survive quitting.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.12))
                .accessibilityAddTraits(.isStaticText)
            }

            NavigationSplitView {
                List(selection: paneSelection) {
                    ForEach(LibraryPane.Group.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(group.panes) { pane in
                                row(for: pane).tag(pane)
                            }
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 220)
            } detail: {
                detail
                    .navigationTitle(model.pane.title)
            }
        }
    }

    /// `List` wants an optional selection; the model's is not, because a detail
    /// pane always has to be showing something. Deselecting keeps the current
    /// pane rather than emptying the window.
    private var paneSelection: Binding<LibraryPane?> {
        Binding(
            get: { model.pane },
            set: { selected in if let selected { model.pane = selected } }
        )
    }

    @ViewBuilder
    private func row(for pane: LibraryPane) -> some View {
        HStack(spacing: 0) {
            Label(pane.title, systemImage: pane.symbol)
            // The one thing a sidebar must be able to say without being clicked.
            // The menu bar glyph and the island's resting tint carry the same
            // warning, but neither is visible with this window in front of them.
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
        case .history: HistoryPane()
        case .dictionary: DictionaryPane()
        case .snippets: SnippetsPane()
        case .stats: StatsPane()
        case .general: GeneralPane()
        case .dictation: DictationPane(model: model, coordinator: coordinator)
        case .speech: SpeechPane(coordinator: coordinator)
        case .cleanup: CleanupPane(coordinator: coordinator)
        case .permissions: PermissionsPane(model: model)
        case .sound: SoundPane()
        }
    }
}
