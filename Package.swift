// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KeyDrop",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CSQLite",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "KeyDrop",
            dependencies: ["CSQLite"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
