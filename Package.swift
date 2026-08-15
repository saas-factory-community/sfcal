// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sfcal",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SFCal",
            path: "Sources/SFCal",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SFCalTests",
            dependencies: ["SFCal"],
            path: "Tests/SFCalTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
