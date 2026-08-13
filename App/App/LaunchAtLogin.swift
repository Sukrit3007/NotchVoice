import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService. Registering throws when the app is not in
/// a stable location (a DerivedData build, for instance), so failures are
/// reported rather than silently swallowed.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.settings.error(
                    "Launch at login failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
