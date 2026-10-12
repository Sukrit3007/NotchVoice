import AppKit
import NotchVoiceCore
import Observation

/// Status-bar item: the only chrome a background app gets. Shows permission
/// state, the current binding, and a way to quit.
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private let coordinator: DictationCoordinator
    private let library: LibraryWindowController
    private let updates: UpdateController
    private let secureInput = SecureInputMonitor()

    /// What the glyph currently shows, so a readiness change that does not cross
    /// the blocked/not-blocked line does not touch the button.
    private var shownAsBlocked: Bool?

    init(
        coordinator: DictationCoordinator,
        library: LibraryWindowController,
        updates: UpdateController
    ) {
        self.coordinator = coordinator
        self.library = library
        self.updates = updates
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A status item is composited into the Window Server's own menu bar
        // rather than appearing as a window this app owns, so nothing outside
        // the process can observe whether it rendered. This is the only signal
        // available: a nil button means it will never show, and for a
        // background app with no other chrome that is silent death.
        guard item.button != nil else {
            Log.settings.error("Status item has no button — menu bar item will NOT appear")
            return
        }
        item.menu = buildMenu()
        statusItem = item
        applyIcon()

        secureInput.start()
        observeReadiness()

        Log.settings.info("Menu bar item installed")
    }

    /// Keeps the glyph in step with readiness.
    ///
    /// The island only tints its resting glyph when something is wrong, and that
    /// glyph can be clipped by a wide menu bar or hidden on an external display.
    /// This is the signal that is always visible.
    ///
    /// Re-arms itself, because `withObservationTracking` fires `onChange` exactly
    /// once — observing a value *over time* means installing a fresh tracker from
    /// inside the callback. The hop is also required: `onChange` runs
    /// **before** the new value is stored, so reading it synchronously returns
    /// the old one.
    private func observeReadiness() {
        withObservationTracking {
            _ = coordinator.readiness
            _ = secureInput.isBlocking
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                applyIcon()
                observeReadiness()
            }
        }
    }

    /// The app's mark, and its only always-visible warning.
    ///
    /// An emoji rather than an SF Symbol, which costs something worth naming:
    /// emoji are colour bitmaps, not template images, so this does not tint with
    /// the menu bar, does not invert when the menu is open, and cannot carry a
    /// badge. The warning is therefore signalled by swapping the whole glyph
    /// rather than by badging it.
    ///
    /// Secure Input held by another app counts as blocked too: from the user's
    /// side it looks exactly like a missing permission — the key does nothing.
    private func applyIcon() {
        var blocked: Bool
        switch coordinator.readiness {
        case .needsPermission, .modelUnavailable: blocked = true
        case .ready, .loadingModel: blocked = false
        }
        if secureInput.isBlocking { blocked = true }

        guard blocked != shownAsBlocked else { return }
        shownAsBlocked = blocked

        guard let button = statusItem?.button else { return }
        // Cleared explicitly. A status item renders its image *and* its title,
        // so the previous SF Symbol would otherwise sit next to the emoji.
        button.image = nil
        button.title = blocked ? "⚠️" : "🗣️"
        // `NSImage(systemSymbolName:accessibilityDescription:)` carried this for
        // free; a title does not, and without it VoiceOver reads the emoji's own
        // name — "speaking head" — instead of the app's.
        button.setAccessibilityLabel(
            blocked ? "Notch Voice — attention needed" : "Notch Voice")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Items are enabled explicitly below. Left on, AppKit decides
        // enablement by walking the responder chain and overrides every
        // `isEnabled` set here, which makes the permission rows' disabled
        // state a coincidence rather than a decision.
        menu.autoenablesItems = false
        menu.delegate = MenuRefresher.shared
        MenuActions.shared.library = library
        MenuActions.shared.updates = updates
        MenuActions.shared.coordinator = coordinator
        MenuRefresher.shared.rebuild = { [weak self] in self?.rebuildItems(in: $0) }
        rebuildItems(in: menu)
        return menu
    }

    private func rebuildItems(in menu: NSMenu) {
        menu.removeAllItems()

        let binding = BindingStore.binding
        let header = NSMenuItem(
            title: "Hold \(binding.displayName) to dictate",
            action: nil, keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        // Directly under the line it qualifies.
        if secureInput.isBlocking {
            let holder = secureInput.holderName ?? "another app"
            let warning = NSMenuItem(
                title: "Secure Input is on in \(holder)", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            warning.toolTip = "While it is on, macOS keeps keystrokes from Notch Voice. "
                + "Password fields and Terminal's Secure Keyboard Entry turn it on."
            menu.addItem(warning)

            let consequence = NSMenuItem(
                title: "Shortcuts may not respond until it's off", action: nil, keyEquivalent: "")
            consequence.isEnabled = false
            menu.addItem(consequence)
        }
        menu.addItem(.separator())

        let status = PermissionChecker.status()
        for kind in PermissionChecker.Kind.allCases {
            addPermissionItem(to: menu, kind: kind, granted: status.isGranted(kind))
        }

        menu.addItem(.separator())

        // The shortcut is shown so it can be found here, and works anywhere:
        // the event tap takes ⌃⌘V before this menu could ever see it.
        let pasteLast = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(MenuActions.pasteLast),
            keyEquivalent: "v"
        )
        pasteLast.keyEquivalentModifierMask = [.control, .command]
        pasteLast.target = MenuActions.shared
        pasteLast.isEnabled = coordinator.canPasteLast
        menu.addItem(pasteLast)

        // The only preference that stays in the menu.
        //
        // Muting is done in a hurry — the tone before a call starts, not a
        // setting you sit down to change — and two clicks here beats opening a
        // window and finding a pane. Launch at Login is the opposite: set once,
        // never touched, so it lives in Settings alone rather than earning a
        // permanent row. Both read the same store either way, so there is no
        // second source of truth to keep in agreement.
        let sounds = NSMenuItem(
            title: "Play Sounds",
            action: #selector(MenuActions.toggleSounds),
            keyEquivalent: ""
        )
        sounds.target = MenuActions.shared
        sounds.state = SoundPreference.isEnabled ? .on : .off
        sounds.isEnabled = true
        menu.addItem(sounds)

        // Two doors into one window. Named for what is behind them rather than
        // one vague "Notch Voice…", because a menu item that does not say where
        // it lands has to be clicked to find out.
        for (title, action) in [
            ("History…", #selector(MenuActions.openHistory)),
            ("Settings…", #selector(MenuActions.openSettings)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = MenuActions.shared
            item.isEnabled = true
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Below Settings rather than beside Quit: it is a thing the app does,
        // not a way out of it. Disabled while a check is already running, which
        // is the only state where clicking it does nothing.
        let update = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(MenuActions.checkForUpdates),
            keyEquivalent: ""
        )
        update.target = MenuActions.shared
        update.isEnabled = MenuActions.shared.updates?.canCheckForUpdates ?? false
        menu.addItem(update)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Notch Voice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        // With autoenablesItems off, an item with no target is never resolved
        // up the responder chain, so Quit would render permanently greyed out.
        quit.target = NSApp
        quit.isEnabled = true
        menu.addItem(quit)
    }

    private func addPermissionItem(
        to menu: NSMenu,
        kind: PermissionChecker.Kind,
        granted: Bool
    ) {
        // Deliberately no "(auto-paste)" suffix on Accessibility. The hotkey
        // itself depends on it, so describing it as a convenience would say the
        // opposite of the truth.
        let item = NSMenuItem(
            title: "\(granted ? "✓" : "✗")  \(kind.title)",
            // Routed to our own Settings rather than straight into System
            // Settings. The Permissions pane is what performs the prompt that
            // gets this app *listed* in the relevant System Settings pane, and
            // what proves afterwards that the grant took effect — deep-linking
            // alone can drop the user on a list with nothing to switch on.
            action: granted ? nil : #selector(MenuActions.openPermissions),
            keyEquivalent: ""
        )
        item.target = granted ? nil : MenuActions.shared
        // A granted permission is a statement, not a control: nothing useful
        // happens on click, so it reads as disabled.
        item.isEnabled = !granted
        menu.addItem(item)
    }
}

/// Rebuilds the menu each time it opens so permission ticks are never stale.
@MainActor
private final class MenuRefresher: NSObject, NSMenuDelegate {
    static let shared = MenuRefresher()
    var rebuild: ((NSMenu) -> Void)?

    func menuWillOpen(_ menu: NSMenu) {
        rebuild?(menu)
    }
}

@MainActor
private final class MenuActions: NSObject {
    static let shared = MenuActions()

    /// Weak: the controller owns the window, this only reaches it. A strong
    /// reference from a singleton would keep it alive for the process.
    weak var library: LibraryWindowController?

    /// Also weak, and for the same reason — the app delegate owns it.
    weak var updates: UpdateController?

    /// Weak for the same reason again.
    weak var coordinator: DictationCoordinator?

    /// The status menu does not activate this app, so whatever was frontmost
    /// before the menu opened is still frontmost — which is where this pastes.
    @objc func pasteLast() {
        coordinator?.pasteLast()
    }

    @objc func checkForUpdates() {
        updates?.checkForUpdates()
    }

    @objc func toggleSounds() {
        SoundPreference.isEnabled.toggle()
    }

    @objc func openHistory() {
        library?.show(pane: .history)
    }

    @objc func openSettings() {
        library?.show(pane: .general)
    }

    /// Jumps straight to the pane that can fix the row that was clicked.
    @objc func openPermissions() {
        library?.show(pane: .permissions)
    }
}
