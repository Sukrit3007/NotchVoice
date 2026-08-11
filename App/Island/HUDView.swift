import SwiftUI

/// Fallback presentation for screens with no notch.
///
/// Styled after the system volume HUD rather than a fake notch — pretending a
/// cutout exists where there is none reads as wrong (spec §7).
///
/// NOTE: the exact corner radius, material, size and drop-down animation are
/// placeholders until they are matched against the real system HUD. To do
/// that: trigger a volume change, screenshot it with `⌘⇧4`, and adjust these
/// constants to match. Not yet done — it needs a human eye on both at once.
struct HUDView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}
