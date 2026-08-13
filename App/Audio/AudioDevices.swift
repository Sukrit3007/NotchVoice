import CoreAudio
import Foundation

/// The microphones this Mac can hear through.
///
/// CoreAudio rather than `AVCaptureDevice`, because the engine has to be told
/// which device to use by `AudioDeviceID` and there is no supported way to get
/// one from an `AVCaptureDevice`. Enumerating in the same API that consumes the
/// result avoids a lookup that can fail.
enum AudioDevices {

    struct Device: Identifiable, Hashable, Sendable {
        /// Valid only for this boot — CoreAudio reuses IDs across reconnects.
        let id: AudioDeviceID
        /// Stable across reboots and reconnects. What gets persisted.
        let uid: String
        let name: String
    }

    /// Every device with at least one input channel.
    ///
    /// The input-stream check is what excludes output-only hardware: CoreAudio
    /// reports one flat list of devices, and a pair of speakers is in it.
    static func inputs() -> [Device] {
        deviceIDs()
            .filter { hasInputChannels($0) }
            .compactMap { id in
                guard let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                      let name = string(id, selector: kAudioObjectPropertyName)
                else { return nil }
                return Device(id: id, uid: uid, name: name)
            }
    }

    /// Whatever the system would pick. Nil when the Mac has no input at all —
    /// a clamshell Mac mini with nothing plugged in.
    static func systemDefault() -> Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != 0 else { return nil }
        return inputs().first { $0.id == id }
    }

    /// Resolves a remembered device, or nil when it is no longer attached.
    ///
    /// Looked up by UID rather than by `AudioDeviceID` because IDs are reused:
    /// unplugging one interface and plugging in another can hand the new one the
    /// old one's ID, and the app would silently record from the wrong thing.
    static func device(uid: String) -> Device? {
        inputs().first { $0.uid == uid }
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return false }

        // AudioBufferList is variable-length, so it is allocated raw rather than
        // declared — a fixed-size stack value would be overrun by a device with
        // more buffers than assumed.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return false }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
