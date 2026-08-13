import Testing
import CoreAudio
@testable import NotchVoice

/// CoreAudio enumeration depends on what is plugged into the machine, so these
/// assert *invariants* rather than a device list. A test that demands a built-in
/// microphone passes on a laptop and fails on a Mac mini, which makes it a
/// statement about the hardware rather than about the code.
@Suite("Audio devices")
struct AudioDeviceTests {

    @Test("every enumerated device is usable as a choice")
    func devicesAreWellFormed() {
        for device in AudioDevices.inputs() {
            // A blank UID cannot be persisted or resolved, and a blank name
            // renders as an empty row in the picker.
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(device.id != 0)
        }
    }

    @Test("UIDs are unique, because they are the stored identity")
    func uidsAreUnique() {
        // Two devices sharing a UID would make the remembered choice ambiguous.
        let uids = AudioDevices.inputs().map(\.uid)
        #expect(Set(uids).count == uids.count)
    }

    @Test("the system default, when there is one, is an input")
    func defaultIsAnInput() {
        guard let fallback = AudioDevices.systemDefault() else { return }
        #expect(AudioDevices.inputs().contains(fallback))
    }

    @Test("a device can be found again by its UID")
    func lookupRoundTrips() {
        // The whole point of storing a UID rather than an AudioDeviceID.
        guard let first = AudioDevices.inputs().first else { return }
        #expect(AudioDevices.device(uid: first.uid) == first)
    }

    @Test("an unknown UID resolves to nothing, not to the wrong device")
    func unknownUIDIsNil() {
        // The failure this guards is silent and awful: recording from a
        // different microphone than the one chosen.
        #expect(AudioDevices.device(uid: "not-a-real-device-uid") == nil)
    }
}

@Suite("Microphone preference")
struct MicPreferenceTests {

    /// Saved and restored so a test run cannot change what the app records from.
    private func withCleanPreference(_ body: () throws -> Void) rethrows {
        let original = MicPreference.uid
        defer { MicPreference.uid = original }
        MicPreference.uid = nil
        try body()
    }

    @Test("no choice means follow the system")
    func defaultFollowsSystem() {
        withCleanPreference {
            let (device, wasMissing) = MicPreference.resolve()
            #expect(!wasMissing)
            #expect(device == AudioDevices.systemDefault())
        }
    }

    @Test("a chosen device that isn't attached falls back and says so")
    func missingDeviceFallsBack() {
        withCleanPreference {
            MicPreference.uid = "a-device-that-is-not-here"
            let (device, wasMissing) = MicPreference.resolve()
            // Falls back rather than failing: a missing microphone is a reason
            // to warn, not a reason to lose the dictation.
            #expect(wasMissing)
            #expect(device == AudioDevices.systemDefault())
        }
    }

    @Test("clearing the choice removes it rather than storing empty")
    func clearingRemoves() {
        withCleanPreference {
            MicPreference.uid = "something"
            MicPreference.uid = nil
            // An empty string would resolve as a device that does not exist and
            // report wasMissing forever.
            #expect(MicPreference.uid == nil)
            #expect(!MicPreference.resolve().wasMissing)
        }
    }
}

@Suite("Dictation language")
struct DictationLanguageTests {

    @Test("automatic has no code, which is what the decoder needs")
    func automaticIsNil() {
        #expect(DictationLanguage.automatic.code == nil)
        #expect(DictationLanguage.fixed("en").code == "en")
    }

    @Test("every offered language has a readable name")
    func offeredLanguagesAreNamed() {
        for language in DictationLanguage.offered {
            #expect(!language.title.isEmpty)
            // A code that Locale cannot name would render as "PT-BR" in a list
            // of proper names.
            #expect(language.title.count > 1)
        }
    }

    @Test("automatic is offered exactly once and comes first")
    func automaticLeadsTheList() {
        #expect(DictationLanguage.offered.first == .automatic)
        #expect(DictationLanguage.offered.filter { $0 == .automatic }.count == 1)
    }

    @Test("the preference round-trips, including automatic")
    func preferenceRoundTrips() {
        let original = LanguagePreference.current
        defer { LanguagePreference.current = original }

        LanguagePreference.current = .automatic
        #expect(LanguagePreference.current == .automatic)

        LanguagePreference.current = .fixed("ja")
        #expect(LanguagePreference.current == .fixed("ja"))
    }
}

@Suite("Speech model")
struct SpeechModelTests {

    @Test("every model describes what it costs", arguments: SpeechModel.allCases)
    func modelsAreDescribed(_ model: SpeechModel) {
        #expect(!model.title.isEmpty)
        #expect(!model.detail.isEmpty)
        #expect(model.approximateSize.contains("MB"))
        // The raw value is a WhisperKit variant name, and a typo there is a
        // download that 404s at first use.
        #expect(model.rawValue.hasPrefix("openai_whisper"))
    }

    @Test("an unrecognised stored model falls back rather than failing")
    func unknownStoredModelFallsBack() {
        let original = ModelPreference.current
        defer { ModelPreference.current = original }

        // What a downgrade looks like: a newer build wrote a variant this one
        // has never heard of.
        UserDefaults.standard.set("openai_whisper-from-the-future", forKey: "speechModel")
        #expect(ModelPreference.current == .turbo)
    }
}

