import AppKit
import NotchVoiceCore

/// Status-bar item: the only chrome a background app gets. Shows permission
/// state, the current binding, and a way to quit.
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private let coordinator: DictationCoordinator

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A status item is composited into the Window Server's own menu bar
        // rather than appearing as a window this app owns, so nothing outside
        // the process can observe whether it rendered. This is the only signal
        // available: a nil button means it will never show, and for a
        // background app with no other chrome that is silent death.
        guard let button = item.button else {
            NSLog("[NotchVoice] status item has no button — menu bar item will NOT appear")
            return
        }
        button.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "NotchVoice"
        )
        item.menu = buildMenu()
        statusItem = item
        NSLog("[NotchVoice] menu bar item installed")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Items are enabled explicitly below. Left on, AppKit decides
        // enablement by walking the responder chain and overrides every
        // `isEnabled` set here, which makes the permission rows' disabled
        // state a coincidence rather than a decision.
        menu.autoenablesItems = false
        menu.delegate = MenuRefresher.shared
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
        menu.addItem(.separator())

        let status = PermissionChecker.status()
        addPermissionItem(to: menu, title: "Microphone",
                          granted: status.microphone, kind: .microphone)
        addPermissionItem(to: menu, title: "Input Monitoring",
                          granted: status.inputMonitoring, kind: .inputMonitoring)
        addPermissionItem(to: menu, title: "Accessibility (auto-paste)",
                          granted: status.accessibility, kind: .accessibility)

        menu.addItem(.separator())

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(MenuActions.toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = MenuActions.shared
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        launch.isEnabled = true
        menu.addItem(launch)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit NotchVoice",
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
        title: String,
        granted: Bool,
        kind: PermissionChecker.Kind
    ) {
        let item = NSMenuItem(
            title: "\(granted ? "✓" : "✗")  \(title)",
            action: granted ? nil : #selector(MenuActions.openPermission(_:)),
            keyEquivalent: ""
        )
        item.target = granted ? nil : MenuActions.shared
        item.representedObject = kind
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

    @objc func toggleLaunchAtLogin() {
        LaunchAtLogin.isEnabled.toggle()
    }

    @objc func openPermission(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? PermissionChecker.Kind else {
            return
        }
        // The prompt is what actually gets the app listed in the Accessibility
        // pane. Opening Settings alone can land the user on an empty list with
        // nothing to switch on.
        if kind == .accessibility {
            Paster.promptForAccessibility()
        }
        PermissionChecker.openSettings(for: kind)
    }
}
