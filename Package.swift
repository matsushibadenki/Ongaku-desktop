// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OngakuDesktop",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OngakuDesktop", targets: ["OngakuDesktop"])
    ],
    targets: [
        .executableTarget(
            name: "OngakuDesktop",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OngakuDesktopTests",
            dependencies: ["OngakuDesktop"]
        )
    ]
)
