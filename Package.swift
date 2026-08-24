// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaInfo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MediaInfo", targets: ["MediaInfo"])
    ],
    targets: [
        .executableTarget(
            name: "MediaInfo",
            path: "Sources/MediaInfo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
