import AppKit
import SwiftUI

/// The icon of the app a transcript went to.
///
/// Resolved from the bundle identifier at display time and cached, because
/// `NSWorkspace` has to hit the disk for it and a history list asks for the same
/// handful of apps over and over.
///
/// Returns nil rather than a generic placeholder when the app is gone. A row for
/// an uninstalled app still has its name — captured when the dictation happened
/// — and a grey question mark next to it would add nothing.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }

        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}

/// A small app icon, or the space where one would be.
///
/// The placeholder keeps its width even when there is no icon, so the text in
/// every row starts at the same x. A list whose left edge moves per row is
/// harder to scan than one with a gap in it.
@MainActor
struct AppIconView: View {
    let bundleID: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = AppIconCache.icon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
