// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Adawat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Adawat",
            path: "Sources/Adawat",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        // swift test: runs wheel choices on sample files made on the spot. Tests/wheel-choices.json is shared with the
        // Windows and Linux tests.
        .testTarget(
            name: "AdawatTests",
            dependencies: ["Adawat"],
            path: "Tests/AdawatTests"
        ),
    ]
)
