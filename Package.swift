// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpotLyricsBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SpotLyricsBar", targets: ["SpotLyricsBar"])
    ],
    targets: [
        .executableTarget(
            name: "SpotLyricsBar",
            path: "Sources/SpotLyricsBar"
        )
    ]
)
