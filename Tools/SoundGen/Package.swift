// swift-tools-version: 6.0
import PackageDescription

// Build-time only. Nothing here is linked into the app — it renders the four
// feedback cues to .wav and the app plays the files.
let package = Package(
    name: "SoundGen",
    platforms: [.macOS("14.0")],
    targets: [
        .target(name: "ToneKit"),
        .executableTarget(name: "soundgen", dependencies: ["ToneKit"]),
        .testTarget(name: "ToneKitTests", dependencies: ["ToneKit"]),
    ]
)
