import SwiftUI
import NotchVoiceCore

/// Proof that the dictation key actually reaches the app.
///
/// The whole reason the Settings window exists. `IOHIDCheckAccess` reporting
/// "granted" does not prove events will arrive, so the only honest test is to
/// wait for a real keystroke — and only offer a restart when waiting produces
/// nothing.
struct HotkeyTestRow: View {
    var model: SettingsModel
    var coordinator: DictationCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch model.test {
        case .blocked:
            SettingsStatusRow(
                symbol: "lock.fill", tint: .secondary,
                title: "Can't test yet",
                detail: "Notch Voice needs its permissions before it can see the key."
            ) {
                Button("Permissions") { model.pane = .permissions }
            }

        case .idle:
            SettingsStatusRow(
                symbol: "questionmark.circle", tint: .secondary,
                title: "Not checked yet",
                detail: "Confirm \(model.binding.displayName) reaches Notch Voice."
            ) {
                Button("Test", action: model.beginTest)
            }

        case .waiting:
            VStack(alignment: .leading, spacing: 10) {
                SettingsStatusRow(
                    symbol: "hand.point.up.left.fill", tint: .accentColor,
                    title: "Hold \(model.binding.displayName)",
                    detail: "Say anything — this is a real dictation."
                )
                liveMeter
            }

        case .passed:
            SettingsStatusRow(
                symbol: "checkmark.circle.fill", tint: .green,
                title: "Working",
                detail: "Notch Voice heard \(model.binding.displayName)."
            ) {
                Button("Test Again", action: model.beginTest)
            }

        case .notSeenYet:
            VStack(alignment: .leading, spacing: 10) {
                SettingsStatusRow(
                    symbol: "questionmark.circle.fill", tint: .secondary,
                    title: "Haven't seen the key yet",
                    detail: "Press \(model.binding.displayName) to try again. If "
                          + "nothing happens, macOS may need Notch Voice "
                          + "relaunched before it delivers key events."
                )
                HStack(spacing: 8) {
                    Button("Try Again", action: model.beginTest)
                    Button("Quit & Reopen", action: model.restart)
                }
            }

        case .needsRestart:
            VStack(alignment: .leading, spacing: 10) {
                SettingsStatusRow(
                    symbol: "arrow.clockwise.circle.fill", tint: .orange,
                    title: "Restart needed",
                    detail: "macOS won't deliver key events to this copy until "
                          + "it's relaunched."
                )
                Button("Quit & Reopen", action: model.restart)
            }
        }
    }

    /// The same meter the island uses, fed by the same levels — so what the
    /// user sees while testing is what they will see in the notch, not a
    /// mock-up of it. It moves because holding the key starts a genuine
    /// capture; there is no passive listening behind this window.
    private var liveMeter: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isCapturing ? Color.red : .secondary)
                .accessibilityHidden(true)

            WaveformView(
                levels: coordinator.levels,
                muted: coordinator.inputTooQuiet,
                animates: !reduceMotion
            )

            if coordinator.inputTooQuiet {
                Text("Very quiet — check your input device")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .padding(.leading, 28)   // aligns under the title, past the symbol column
    }

    private var isCapturing: Bool {
        coordinator.phase == .recording || coordinator.phase == .locked
    }
}
