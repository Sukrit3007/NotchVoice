import SwiftUI

/// Symbol, title, explanation, and an optional control on the right.
///
/// The shape every status line in Settings uses. It was a generic
/// `line(symbol:tint:title:detail:trailing:)` method on `DictationPane`, which
/// meant the one layout shared by several panes could only be reached from
/// inside one of them.
struct SettingsStatusRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    /// Stored as a built view rather than as an escaping `@ViewBuilder` closure
    /// the row holds onto. The synthesised initialiser still lets callers write
    /// a trailing closure at the call site.
    @ViewBuilder let trailing: Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 18)
                // The title and detail beside it say everything this conveys.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
            trailing
        }
    }
}

extension SettingsStatusRow where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) {
            EmptyView()
        }
    }
}

#Preview {
    Form {
        SettingsStatusRow(
            symbol: "checkmark.circle.fill", tint: .green,
            title: "Working", detail: "Notch Voice heard fn."
        ) {
            Button("Test Again") {}
        }
        SettingsStatusRow(
            symbol: "lock.fill", tint: .secondary,
            title: "Can't test yet",
            detail: "Input Monitoring is what lets Notch Voice see the key."
        )
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
