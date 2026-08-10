import AppKit

@main
final class NotchVoiceApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = NotchVoiceApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[NotchVoice] launched")

        // TEMPORARY: manual verification harness for WhisperKitService (Task 7).
        // Revert this block after a human confirms transcription on real hardware.
        Task { @MainActor in
            // Errors are caught and logged rather than left to propagate: an
            // unhandled throw out of a Task is discarded silently, so a failed
            // transcription would look exactly like a hang — and silence throws
            // TranscriptionError.empty by design.
            do {
                let service = WhisperKitService()
                NSLog("[NotchVoice] preparing model…")
                try await service.prepare { NSLog("[NotchVoice] prepare progress %.2f", $0) }
                NSLog("[NotchVoice] model ready")

                // MicRecorder is @MainActor-isolated and this Task runs on the
                // main actor, so these calls need no hopping.
                let recorder = MicRecorder()
                try recorder.start()
                NSLog("[NotchVoice] recording — speak now (5s)")
                try await Task.sleep(for: .seconds(5))
                let samples = recorder.stop()
                NSLog("[NotchVoice] captured %d samples, transcribing…", samples.count)

                let text = try await service.transcribe(samples)
                NSLog("[NotchVoice] transcript: %@", text)
            } catch {
                NSLog("[NotchVoice] FAILED: %@", String(describing: error))
            }
        }
    }
}
