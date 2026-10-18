import AppKit
import SwiftUI
import Testing
@testable import OngakuDesktop

@Suite("Pastel appearance", .serialized)
@MainActor
struct PastelAppearanceTests {
    @Test("Four persisted palettes match iPhone and restore after reload")
    func palettes() throws {
        let suite = "OngakuPastel.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); DesktopAppearancePalette.shared.selection = .system }
        let settings = AppAppearanceSettings(defaults: defaults)
        let values: [(AppAppearance, UInt32)] = [(.pink, 0xfbeefa), (.purple, 0xeeecfe), (.green, 0xe1fff4), (.beige, 0xfaf7e3)]
        #expect(AppAppearance.allCases.count == 7)
        for (appearance, expected) in values {
            settings.selectedAppearance = appearance
            #expect(AppAppearanceSettings(defaults: defaults).selectedAppearance == appearance)
            #expect(appearance.colorScheme == .light)
            #expect(appearance.pastelHex == expected)
            let color = try #require(NSColor(AppTheme.canvas).usingColorSpace(.sRGB))
            #expect(abs(color.redComponent * 255 - CGFloat((expected >> 16) & 255)) < 0.01)
            #expect(abs(color.greenComponent * 255 - CGFloat((expected >> 8) & 255)) < 0.01)
            #expect(abs(color.blueComponent * 255 - CGFloat(expected & 255)) < 0.01)
        }
        settings.selectedAppearance = .system
        #expect(defaults.object(forKey: AppAppearanceSettings.defaultsKey) == nil)
    }

    @Test("All dial marks and needle levels share the -18 dBFS reference")
    func calibration() {
        for mark in PastelVUMeterScale.marks {
            let input = PastelVUMeterScale.normalizedValue(rmsDBFS: Double(mark.vu) - 18)
            #expect(abs(PastelVUMeterScale.position(forLevel: input) - mark.position) < 1e-9)
        }
        #expect(abs(PastelVUMeterScale.position(forLevel: PastelVUMeterScale.normalizedValue(rmsDBFS: -18)) - 0.73) < 1e-9)
        for value in [Double.nan, -Double.infinity, Double.infinity, -1, 0, 1, 2] {
            let p = PastelVUMeterScale.position(forLevel: value)
            #expect(p.isFinite && (0...1).contains(p))
        }
        for width in [CGFloat(168), 218, 328] {
            let geometry = PastelCompactVUGeometry(size: CGSize(width: width, height: 64))
            for mark in PastelVUMeterScale.marks {
                #expect(CGRect(x: 0, y: 0, width: width, height: 64).contains(geometry.point(position: mark.position)))
            }
        }
    }

    @Test("Production desktop meters and transport render in every color")
    func render() throws {
        defer { DesktopAppearancePalette.shared.selection = .system }
        let output = ProcessInfo.processInfo.environment["ONGAKU_PASTEL_AUDIT_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for appearance in [AppAppearance.pink, .purple, .green, .beige] {
            DesktopAppearancePalette.shared.selection = appearance
            for width in [CGFloat(218), 328] {
                let content = VStack(spacing: 12) {
                    ForEach([0.0, 0.7, 0.75], id: \.self) { level in
                        HStack(spacing: 16) {
                            ChannelVUMeterView(channel: "L", level: level, backlight: .green, isActive: false)
                            ChannelVUMeterView(channel: "R", level: level, backlight: .orange, isActive: false)
                        }
                        .frame(width: width * 2 + 16, height: 80)
                    }
                }
                .padding(16).background(AppTheme.canvas).environment(\.colorScheme, .light)
                try capture(content, name: "\(appearance.rawValue)-meters-\(Int(width))", output: output)
            }
            let defaults = UserDefaults(suiteName: "OngakuPastelRender.\(appearance.rawValue)")!
            defer { defaults.removePersistentDomain(forName: "OngakuPastelRender.\(appearance.rawValue)") }
            let meters = PlayerMeterSettings(defaults: defaults)
            meters.style = .vu
            let bar = PlayerBar().frame(width: 1000, height: PlayerBar.layoutHeight)
                .environmentObject(LibraryStore(repository: LibraryRepository(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("OngakuPastelRender-\(UUID())"))))
                .environmentObject(PlaybackController())
                .environmentObject(AppleMusicPlaybackController())
                .environmentObject(meters)
                .environment(\.colorScheme, .light)
            try capture(bar, name: "\(appearance.rawValue)-player-1000", output: output)
        }
        for mode in [AppAppearance.system, .light, .dark] {
            DesktopAppearancePalette.shared.selection = mode
            try capture(ChannelVUMeterView(channel: "L", level: 0.7, backlight: .cyan)
                .frame(width: 218, height: 80), name: "legacy-\(mode.rawValue)", output: output)
        }
    }

    private func capture<V: View>(_ view: V, name: String, output: URL?) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0 && image.size.height > 0)
        if let output {
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
    }
}
