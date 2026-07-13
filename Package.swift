// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MixerApp",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        // Shared audio-routing engine + models.
        .target(
            name: "MixerCore",
            path: "Sources/MixerCore"
        ),
        // Debug CLI (list devices/processes, route a single app).
        .executableTarget(
            name: "mixerpoc",
            dependencies: ["MixerCore"],
            path: "Sources/mixerpoc"
        ),
        // SwiftUI menu-bar app.
        .executableTarget(
            name: "MixerApp",
            dependencies: ["MixerCore"],
            path: "Sources/MixerApp"
        ),
        .testTarget(
            name: "MixerCoreTests",
            dependencies: ["MixerCore"],
            path: "Tests/MixerCoreTests"
        )
    ]
)
