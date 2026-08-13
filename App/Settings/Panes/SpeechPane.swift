import SwiftUI

/// What the app listens with, what it expects to hear, and what decodes it.
///
/// Split out of Dictation, which was already carrying the key binding, the live
/// hotkey test, context and cleanup. These three are the *inputs* to
/// transcription and they change together — a quieter microphone and a lighter
/// model are the same conversation about accuracy.
@MainActor
struct SpeechPane: View {
    var coordinator: DictationCoordinator

    @State private var devices: [AudioDevices.Device] = []
    @State private var selectedUID: String?
    @State private var language = LanguagePreference.current
    @State private var model = ModelPreference.current

    /// Sentinel for the picker. `nil` cannot be a `tag`, and "follow the system"
    /// has to be selectable rather than merely being what happens when nothing
    /// is chosen.
    private static let systemDefaultTag = ""

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: microphone) {
                    Text("System default").tag(Self.systemDefaultTag)
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // A chosen device that has been unplugged stays in the list
                    // rather than the picker silently jumping to something else.
                    if let missing = missingDeviceUID {
                        Divider()
                        Text("\(shortUID(missing)) — not connected").tag(missing)
                    }
                }
            } header: {
                Text("Input")
            } footer: {
                if missingDeviceUID != nil {
                    Label(
                        "That microphone isn't attached. Dictation is using the system default until it is.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                } else {
                    Text("Which microphone dictation records from.")
                }
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(DictationLanguage.offered) { option in
                        Text(option.title).tag(option)
                    }
                }
            } footer: {
                Text(
                    language == .automatic
                        ? "The model works out the language from what it hears. Slightly slower, and it can pick wrong on a short phrase."
                        : "Telling the model what to expect is faster and more accurate than letting it guess."
                )
            }

            Section {
                Picker("Model", selection: $model) {
                    ForEach(SpeechModel.allCases) { option in
                        Text("\(option.title) — \(option.approximateSize)").tag(option)
                    }
                }
            } header: {
                Text("Speech model")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.detail)
                    if coordinator.readiness == .loadingModel {
                        Label(
                            "Loading. Dictation won't work until this finishes — the first use of a model also downloads it.",
                            systemImage: "arrow.down.circle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: coordinator.readiness)
        .onAppear(perform: refreshDevices)
        .onChange(of: language) { _, new in LanguagePreference.current = new }
        .onChange(of: model) { _, new in coordinator.changeModel(to: new) }
        // Devices come and go while this window sits open, and CoreAudio does not
        // volunteer that. Cheap enough to re-enumerate when the app is activated,
        // which is when a user who just plugged something in comes back.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in refreshDevices() }
    }

    /// Nil unless a device is remembered but not currently attached.
    private var missingDeviceUID: String? {
        guard let uid = selectedUID, !uid.isEmpty else { return nil }
        return devices.contains { $0.uid == uid } ? nil : uid
    }

    private var microphone: Binding<String> {
        Binding(
            get: { selectedUID ?? Self.systemDefaultTag },
            set: {
                selectedUID = $0.isEmpty ? nil : $0
                MicPreference.uid = selectedUID
            }
        )
    }

    private func refreshDevices() {
        devices = AudioDevices.inputs()
        selectedUID = MicPreference.uid
    }

    /// A UID is a long opaque string. Shown trimmed, because the point is to
    /// give the user something recognisable, not to print an identifier.
    private func shortUID(_ uid: String) -> String {
        uid.count > 28 ? String(uid.prefix(28)) + "…" : uid
    }
}
