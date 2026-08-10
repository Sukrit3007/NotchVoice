// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchVoiceCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NotchVoiceCore", targets: ["NotchVoiceCore"]),
    ],
    targets: [
        .target(name: "NotchVoiceCore"),
        .testTarget(name: "NotchVoiceCoreTests", dependencies: ["NotchVoiceCore"]),
    ]
)
