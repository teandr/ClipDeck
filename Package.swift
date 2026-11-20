// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipDeck",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipDeck", targets: ["ClipDeck"]),
        .library(name: "ClipDeckCore", targets: ["ClipDeckCore"])
    ],
    targets: [
        .target(name: "ClipDeckCore"),
        .executableTarget(
            name: "ClipDeck",
            dependencies: ["ClipDeckCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .testTarget(name: "ClipDeckCoreTests", dependencies: ["ClipDeckCore"])
    ],
    swiftLanguageVersions: [.v5]
)
