import SwiftUI

/// Preferences that are not about dictating, hearing, or permissions.
///
/// Thin today — one switch. It exists anyway because General is the first place
/// a Mac user looks, and because it is where model choice and update settings
/// land later without another sidebar reshuffle.
@MainActor
struct GeneralPane: View {

    /// Read from `SMAppService` in `task`, not in this initialiser.
    ///
    /// A `@State` default expression is evaluated every time the struct is
    /// created, which for a SwiftUI view is often — and `SMAppService.mainApp.status`
    /// is a synchronous call into a system service, not a property read. Seeding
    /// it here meant paying for that on every re-render of the parent.
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin, applyLaunchAtLogin)
            } footer: {
                Text("Notch Voice runs in the menu bar. It has no Dock icon and "
                     + "no window of its own except this one.")
            }
        }
        .formStyle(.grouped)
        .task { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    /// Writes the preference, then reads the real state back rather than
    /// assuming the write took. `SMAppService.register()` throws when the app is
    /// not in a stable location — a DerivedData build, for instance — and
    /// `LaunchAtLogin` logs and swallows that. Without the read-back the switch
    /// would sit there claiming something the system had refused.
    private func applyLaunchAtLogin(_ previous: Bool, _ wanted: Bool) {
        LaunchAtLogin.isEnabled = wanted
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

#Preview {
    GeneralPane()
        .frame(width: 460, height: 220)
}
