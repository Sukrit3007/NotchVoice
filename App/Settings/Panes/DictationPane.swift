import SwiftUI
import NotchVoiceCore

/// The key you hold, proof that holding it reaches the app, and what happens to
/// the transcript afterwards.
@MainActor
struct DictationPane: View {
    var model: SettingsModel
    var coordinator: DictationCoordinator

    var body: some View {
        Form {
            Section {
                Picker("Hold to dictate", selection: bindingSelection) {
                    ForEach(ModifierKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
            } footer: {
                Text(bindingExplanation)
            }

            Section("Hotkey") {
                HotkeyTestRow(model: model, coordinator: coordinator)
            }

            Section {
                Toggle("Use what's on screen", isOn: readsScreenContext)
            } header: {
                Text("Accuracy")
            } footer: {
                Text(
                    "Reads the text already in the field you're dictating into and "
                    + "suggests it to the speech model, so names and jargon already "
                    + "on screen come out spelled right. Password fields are never "
                    + "read. Nothing is stored and nothing leaves your Mac."
                )
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: model.test)
    }

    /// Mirrored into `@State` because `ContextPreference` is `UserDefaults`, and
    /// a computed property over defaults is invisible to SwiftUI — the toggle
    /// would flip back on the next redraw.
    @State private var readsScreenContextStorage = ContextPreference.isEnabled

    private var readsScreenContext: Binding<Bool> {
        Binding(
            get: { readsScreenContextStorage },
            set: {
                readsScreenContextStorage = $0
                ContextPreference.isEnabled = $0
            }
        )
    }

    /// Writes through the model, which cancels any gesture in flight before the
    /// tap is replaced. See `DictationCoordinator.rebind(to:)`.
    ///
    /// A `Binding(get:set:)` rather than `@State` plus `onChange`, deliberately:
    /// the model's `binding` is `private(set)` and can change without this view
    /// touching it — `armTap()` downgrades away from fn on a keyboard that has
    /// none. A mirrored `@State` would have to be resynced from the model
    /// anyway, which is the same coupling with an extra copy to keep honest.
    private var bindingSelection: Binding<ModifierKey> {
        Binding(get: { model.binding }, set: { model.rebind(to: $0) })
    }

    private var bindingExplanation: String {
        if model.binding.needsFnKey {
            return "fn does nothing on its own, so Notch Voice can reserve it "
                + "without taking a key you use for anything else. It's held, "
                + "not tapped — fn with another key still works normally."
        }
        return "Right-hand modifiers only. Holding one does nothing in any app, "
            + "so Notch Voice can watch for it without intercepting a keystroke "
            + "— ⌥O still types ø."
    }

}

#Preview {
    // See PermissionsPane's preview: constructing a coordinator here starts
    // nothing.
    let coordinator = DictationCoordinator()
    return DictationPane(
        model: SettingsModel(coordinator: coordinator),
        coordinator: coordinator
    )
    .frame(width: 460, height: 420)
}
