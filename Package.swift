// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OngakuDesktop",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OngakuDesktop", targets: ["OngakuDesktop"])
    ],
    dependencies: [
        .package(path: "Vendor/Sparkle")
    ],
    targets: [
        .target(
            name: "OngakuAudioDSP",
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox")]
        ),
        .executableTarget(
            name: "OngakuDesktop",
            dependencies: [
                "OngakuAudioDSP",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "OngakuDesktopTests",
            dependencies: ["OngakuDesktop"],
            resources: [.copy("Fixtures")]
        )
    ],
    cxxLanguageStandard: .cxx20
)
