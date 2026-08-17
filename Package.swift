// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KeyDrop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeyDrop", targets: ["KeyDrop"]),
        .executable(name: "KeyDropTestRunner", targets: ["KeyDropTestRunner"])
    ],
    targets: [
        .target(
            name: "CSQLite",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "KeyDropCore",
            dependencies: ["CSQLite"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KeyDrop",
            dependencies: ["KeyDropCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KeyDropTestRunner",
            dependencies: ["KeyDropCore"],
            path: "TestSuite",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)