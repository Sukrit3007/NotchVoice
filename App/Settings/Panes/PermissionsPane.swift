import SwiftUI

/// What macOS has and has not granted, and a way to fix each one.
///
/// Every string comes from `PermissionChecker.Kind` rather than being written
/// here, so this pane and the menu bar cannot end up describing the same
/// permission differently.
@MainActor
struct PermissionsPane: View {
    var model: SettingsModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                ForEach(PermissionChecker.Kind.allCases) { kind in
                    row(for: kind)
                }
            } footer: {
                Text("All three are required. Accessibility is what lets "
                     + "Notch Voice reserve the dictation key for itself — "
                     + "without it the key keeps doing whatever macOS does with "
                     + "it, and no dictation starts.")
            }
        }
        .formStyle(.grouped)
    }

    private func row(for kind: PermissionChecker.Kind) -> some View {
        let granted = model.status.isGranted(kind)

        return HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : kind.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(granted ? Color.green : .secondary)
                // Morphs one symbol into the next rather than cross-fading two
                // separate images, so a grant that lands while the window is
                // open reads as the row changing state, not redrawing.
                // Guarded like every other symbol replace in the app — this one
                // was the only place that forgot.
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                Text(kind.whenMissing ?? kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if granted {
                // A statement, not a control. Nothing useful happens on click,
                // so it must not look clickable.
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant") { model.grant(kind) }
            }
        }
        .animation(.smooth(duration: 0.25), value: granted)
    }
}

#Preview {
    // Safe to build here: `DictationCoordinator.init` only sizes its level
    // buffer and state machine — it arms no tap and loads no model. Those
    // happen in `start()`, which a preview never calls.
    PermissionsPane(model: SettingsModel(coordinator: DictationCoordinator()))
        .frame(width: 460, height: 320)
}
