/* Hallmark · pre-emit critique: P5 H4 E4 S5 R5 V4
 * Hallmark · genre: atmospheric · macrostructure: Workbench · theme: Midnight
 * enrichment: none · navigation: native macOS sidebar · header: persistent player
 */
import AppKit
import SwiftUI

private struct ThemeRGB: Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
}

enum AppTheme {
    // Neutral grayscale by day, warm midnight after dark. Elevation remains perceptible in both.
    static let canvas = adaptive(
        light: ThemeRGB(red: 0.955, green: 0.955, blue: 0.955),
        dark: ThemeRGB(red: 0.055, green: 0.052, blue: 0.049)
    )
    static let sidebar = adaptive(
        light: ThemeRGB(red: 0.910, green: 0.910, blue: 0.910),
        dark: ThemeRGB(red: 0.075, green: 0.071, blue: 0.066)
    )
    static let surface = adaptive(
        light: ThemeRGB(red: 0.985, green: 0.985, blue: 0.985),
        dark: ThemeRGB(red: 0.095, green: 0.090, blue: 0.084)
    )
    static let windowBackground = adaptiveNSColor(
        light: ThemeRGB(red: 1.000, green: 1.000, blue: 1.000),
        dark: ThemeRGB(red: 0.000, green: 0.000, blue: 0.000)
    )
    static let windowBar = adaptive(
        light: ThemeRGB(red: 1.000, green: 1.000, blue: 1.000),
        dark: ThemeRGB(red: 0.000, green: 0.000, blue: 0.000)
    )
    static let raised = adaptive(
        light: ThemeRGB(red: 0.875, green: 0.875, blue: 0.875),
        dark: ThemeRGB(red: 0.125, green: 0.117, blue: 0.108)
    )
    static let rule = adaptive(
        light: ThemeRGB(red: 0.700, green: 0.700, blue: 0.700),
        dark: ThemeRGB(red: 0.245, green: 0.225, blue: 0.205)
    )
    static let ink = adaptive(
        light: ThemeRGB(red: 0.130, green: 0.130, blue: 0.130),
        dark: ThemeRGB(red: 0.955, green: 0.943, blue: 0.920)
    )
    static let secondaryInk = adaptive(
        light: ThemeRGB(red: 0.380, green: 0.380, blue: 0.380),
        dark: ThemeRGB(red: 0.730, green: 0.700, blue: 0.660)
    )
    static let accent = adaptive(
        light: ThemeRGB(red: 0.240, green: 0.240, blue: 0.240),
        dark: ThemeRGB(red: 0.965, green: 0.565, blue: 0.180)
    )
    static let good = adaptive(
        light: ThemeRGB(red: 0.300, green: 0.300, blue: 0.300),
        dark: ThemeRGB(red: 0.390, green: 0.760, blue: 0.560)
    )
    static let warning = adaptive(
        light: ThemeRGB(red: 0.400, green: 0.400, blue: 0.400),
        dark: ThemeRGB(red: 0.955, green: 0.670, blue: 0.250)
    )
    static let danger = adaptive(
        light: ThemeRGB(red: 0.180, green: 0.180, blue: 0.180),
        dark: ThemeRGB(red: 0.930, green: 0.390, blue: 0.330)
    )

    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16

    static let spaceXS: CGFloat = 8
    static let spaceSM: CGFloat = 12
    static let spaceMD: CGFloat = 16
    static let spaceLG: CGFloat = 24
    static let spaceXL: CGFloat = 40

    private static func adaptive(light: ThemeRGB, dark: ThemeRGB) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    private static func adaptiveNSColor(light: ThemeRGB, dark: ThemeRGB) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        }
    }
}

extension View {
    func ongakuPanel() -> some View {
        background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous))
    }
}
