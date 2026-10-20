/* Hallmark · pre-emit critique: P4 H4 E4 S5 R4 V4
 * Mobile reference: Ongaku/audio/Appearance.swift · silver / graphite / amber
 * Native desktop workbench; tactile surfaces restricted to chrome and controls.
 */
import AppKit
import SwiftUI

private struct ThemeRGB: Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
}

enum AppTheme {
    @MainActor static var appearance: AppAppearance { DesktopAppearancePalette.shared.selection }
    @MainActor static var canvas: Color { appearance.pastelColor ?? baseCanvas }
    @MainActor static var sidebar: Color { appearance.pastelColor ?? baseSidebar }
    @MainActor static var preferencesSidebar: Color { appearance.pastelColor ?? basePreferencesSidebar }
    @MainActor static var surface: Color { appearance.pastelColor ?? baseSurface }
    @MainActor static var windowBar: Color { appearance.pastelColor ?? baseWindowBar }
    @MainActor static var raised: Color { appearance.pastelColor ?? baseRaised }
    @MainActor static var transportGroove: Color { appearance.accentColor.map { $0.opacity(0.13) } ?? baseTransportGroove }
    @MainActor static var playbackAccent: Color { appearance.accentColor ?? basePlaybackAccent }
    // Match the mobile hardware palette while preserving native macOS appearance switching.
    private static let baseCanvas = adaptive(
        light: ThemeRGB(red: 0.957, green: 0.957, blue: 0.957),
        dark: ThemeRGB(red: 0.130, green: 0.130, blue: 0.130)
    )
    private static let baseSidebar = adaptive(
        light: ThemeRGB(red: 0.957, green: 0.957, blue: 0.957),
        dark: ThemeRGB(red: 0.130, green: 0.130, blue: 0.130)
    )
    private static let basePreferencesSidebar = adaptive(
        light: ThemeRGB(red: 0.925, green: 0.925, blue: 0.925),
        dark: ThemeRGB(red: 0.170, green: 0.170, blue: 0.170)
    )
    private static let baseSurface = adaptive(
        light: ThemeRGB(red: 0.984, green: 0.984, blue: 0.984),
        dark: ThemeRGB(red: 0.145, green: 0.145, blue: 0.145)
    )
    static let windowBackground = adaptiveNSColor(
        light: ThemeRGB(red: 1.000, green: 1.000, blue: 1.000),
        dark: ThemeRGB(red: 0.130, green: 0.130, blue: 0.130)
    )
    private static let baseWindowBar = adaptive(
        light: ThemeRGB(red: 1.000, green: 1.000, blue: 1.000),
        dark: ThemeRGB(red: 0.130, green: 0.130, blue: 0.130)
    )
    private static let baseRaised = adaptive(
        light: ThemeRGB(red: 0.925, green: 0.925, blue: 0.925),
        dark: ThemeRGB(red: 0.180, green: 0.180, blue: 0.180)
    )
    private static let baseTransportGroove = adaptive(
        light: ThemeRGB(red: 0.820, green: 0.820, blue: 0.820),
        dark: ThemeRGB(red: 0.150, green: 0.150, blue: 0.150)
    )
    static let rule = adaptive(
        light: ThemeRGB(red: 0.860, green: 0.860, blue: 0.860),
        dark: ThemeRGB(red: 0.190, green: 0.190, blue: 0.190)
    )
    static let ink = adaptive(
        light: ThemeRGB(red: 0.130, green: 0.130, blue: 0.130),
        dark: ThemeRGB(red: 0.820, green: 0.820, blue: 0.820)
    )
    static let secondaryInk = adaptive(
        light: ThemeRGB(red: 0.320, green: 0.320, blue: 0.320),
        dark: ThemeRGB(red: 0.650, green: 0.650, blue: 0.650)
    )
    // General controls remain neutral; reserve the signal color for playback.
    static let accent = ink
    private static let basePlaybackAccent = adaptive(
        light: ThemeRGB(red: 1.000, green: 0.475, blue: 0.000),
        dark: ThemeRGB(red: 1.000, green: 0.541, blue: 0.110)
    )
    @MainActor static var prominentInk: Color { canvas }
    static let orangeStatus = secondaryInk
    static let playerControl = ink
    @MainActor static var surfaceHighlight: Color { appearance.pastelHighlightColor ?? baseSurfaceHighlight }
    private static let baseSurfaceHighlight = adaptive(
        light: ThemeRGB(red: 1, green: 1, blue: 1),
        dark: ThemeRGB(red: 0.180, green: 0.180, blue: 0.180)
    )
    static let contactShadow = Color.black.opacity(0.16)
    @MainActor static var metal: LinearGradient {
        let colors = appearance.pastelColor.map { [surfaceHighlight, $0] }
            ?? [surfaceHighlight, surface, canvas]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    @MainActor static var raisedEdge: LinearGradient {
        LinearGradient(colors: [surfaceHighlight, rule],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let good = adaptive(
        light: ThemeRGB(red: 0.300, green: 0.300, blue: 0.300),
        dark: ThemeRGB(red: 0.390, green: 0.760, blue: 0.560)
    )
    static let warning = adaptive(
        light: ThemeRGB(red: 0.400, green: 0.400, blue: 0.400),
        dark: ThemeRGB(red: 1.000, green: 1.000, blue: 1.000)
    )
    static let danger = adaptive(
        light: ThemeRGB(red: 0.180, green: 0.180, blue: 0.180),
        dark: ThemeRGB(red: 0.930, green: 0.390, blue: 0.330)
    )

    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 16
    static let radiusLarge: CGFloat = 16

    static let spaceXS: CGFloat = 8
    static let spaceSM: CGFloat = 12
    static let spaceMD: CGFloat = 16
    static let spaceLG: CGFloat = 24
    static let spaceXL: CGFloat = 40
    static let bottomPlayerClearance: CGFloat = 128

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
    func ongakuProminentButton() -> some View {
        buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .foregroundStyle(AppTheme.prominentInk)
    }

    func ongakuPanel() -> some View {
        background {
            RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                .fill(AppTheme.metal)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                        .strokeBorder(AppTheme.raisedEdge, lineWidth: 1)
                }
        }
    }
}

/// Mobile HardwareDial adapted to mouse targets; no continuously animated texture.
struct OngakuTransportButtonStyle: ButtonStyle {
    var primary = false
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        TransportFace(configuration: configuration, primary: primary, active: active)
    }

    private struct TransportFace: View {
        let configuration: ButtonStyleConfiguration
        let primary: Bool
        let active: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(AppTheme.ink)
                .background {
                    Circle().fill(AppTheme.transportGroove)
                        .overlay(Circle().strokeBorder(AppTheme.rule, lineWidth: 1))
                        .overlay {
                            Circle().fill(AppTheme.metal)
                                .overlay(Circle().strokeBorder(AppTheme.raisedEdge, lineWidth: 1))
                                .padding(primary ? 5 : 3)
                                .shadow(color: AppTheme.contactShadow,
                                        radius: configuration.isPressed ? 0 : 1,
                                        x: 0, y: configuration.isPressed ? 0 : 1)
                        }
                        .overlay {
                            Circle().strokeBorder(
                                primary && isEnabled
                                    ? AppTheme.playbackAccent.opacity(active || isHovered ? 1 : 0.75)
                                    : (isHovered && isEnabled ? AppTheme.ink : AppTheme.rule),
                                lineWidth: primary ? 2 : 1
                            )
                        }
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}
