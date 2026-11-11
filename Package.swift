// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blink",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Blink",
            path: "Sources/Blink",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "BlinkTests",
            dependencies: ["Blink"],
            path: "Tests/BlinkTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
