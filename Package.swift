// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "AudioRing", path: "Sources/AudioRing", publicHeadersPath: "include"),
        .executableTarget(name: "Hush", dependencies: ["AudioRing"], path: "Sources/Hush"),
        .testTarget(name: "HushTests", dependencies: ["Hush", "AudioRing"], path: "Tests")
    ]
)
