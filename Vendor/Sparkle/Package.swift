// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Sparkle", targets: ["Sparkle"])
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            path: "Sparkle.xcframework"
        )
    ]
)
