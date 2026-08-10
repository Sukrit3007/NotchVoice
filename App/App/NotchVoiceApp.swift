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

        // TEMPORARY: manual verification harness for MicRecorder (Task 6).
        // Revert this block after a human confirms capture + levels on real hardware.
        Task { @MainActor in
            let recorder = MicRecorder()
            recorder.onLevel = { NSLog("[NotchVoice] level %.3f", $0) }
            try? recorder.start()
            try? await Task.sleep(for: .seconds(3))
            let samples = recorder.stop()
            NSLog("[NotchVoice] captured %d samples (%.2fs at 16kHz)",
                  samples.count, Double(samples.count) / 16_000)
        }
    }
}
