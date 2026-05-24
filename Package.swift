// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiscordDroverMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DiscordDrover", targets: ["DiscordDrover"]),
        .library(name: "DroverShim", type: .dynamic, targets: ["DroverShim"])
    ],
    targets: [
        .executableTarget(
            name: "DiscordDrover",
            path: "Sources/DiscordDrover"
        ),
        .target(
            name: "DroverShim",
            path: "Sources/DroverShim",
            publicHeadersPath: "include"
        )
    ]
)

