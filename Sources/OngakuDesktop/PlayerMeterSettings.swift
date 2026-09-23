import Combine
import SwiftUI

enum PlayerMeterStyle: String, CaseIterable, Identifiable, Sendable {
    case spectrum
    case vu

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .spectrum: "settings.meter.style.spectrum"
        case .vu: "settings.meter.style.vu"
        }
    }
}

enum PlayerBarPosition: String, CaseIterable, Identifiable, Sendable {
    case bottom
    case top

    var id: String { rawValue }

    var localizationKey: String {
        "settings.playerPosition.\(rawValue)"
    }
}

enum VUMeterBacklight: String, CaseIterable, Identifiable, Sendable {
    case cyan
    case green
    case orange
    case yellow

    var id: String { rawValue }

    var localizationKey: String {
        "settings.meter.backlight.\(rawValue)"
    }

    var color: Color {
        switch self {
        case .cyan: Color(red: 0.25, green: 0.88, blue: 1.0)
        case .green: Color(red: 0.38, green: 1.0, blue: 0.52)
        case .orange: Color(red: 1.0, green: 0.48, blue: 0.14)
        case .yellow: Color(red: 1.0, green: 0.88, blue: 0.25)
        }
    }
}

enum SpectrumBarColor: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case white
    case black
    case cyan
    case green
    case orange

    var id: String { rawValue }

    var localizationKey: String {
        "settings.meter.spectrumColor.\(rawValue)"
    }

    func color(isDark: Bool) -> Color {
        switch self {
        case .automatic: isDark ? .white : .black
        case .white: .white
        case .black: .black
        case .cyan: Color(red: 0.25, green: 0.88, blue: 1.0)
        case .green: Color(red: 0.38, green: 1.0, blue: 0.52)
        case .orange: Color(red: 1.0, green: 0.48, blue: 0.14)
        }
    }
}

@MainActor
final class PlayerMeterSettings: ObservableObject {
    nonisolated static let styleDefaultsKey = "player.meter.style.v1"
    nonisolated static let backlightDefaultsKey = "player.meter.backlight.v1"
    nonisolated static let barPositionDefaultsKey = "player.bar.position.v1"
    nonisolated static let spectrumBackgroundOpacityDefaultsKey =
        "player.meter.spectrumBackgroundOpacity.v1"
    nonisolated static let spectrumBarColorDefaultsKey = "player.meter.spectrumBarColor.v1"
    nonisolated static let defaultSpectrumBackgroundOpacity = 1.0
    nonisolated static let spectrumBackgroundOpacityRange = 0.0...1.0

    @Published var style: PlayerMeterStyle {
        didSet { defaults.set(style.rawValue, forKey: Self.styleDefaultsKey) }
    }

    @Published var backlight: VUMeterBacklight {
        didSet { defaults.set(backlight.rawValue, forKey: Self.backlightDefaultsKey) }
    }

    @Published var barPosition: PlayerBarPosition {
        didSet { defaults.set(barPosition.rawValue, forKey: Self.barPositionDefaultsKey) }
    }

    @Published var spectrumBackgroundOpacity: Double {
        didSet {
            let clamped = min(
                max(spectrumBackgroundOpacity, Self.spectrumBackgroundOpacityRange.lowerBound),
                Self.spectrumBackgroundOpacityRange.upperBound
            )
            if spectrumBackgroundOpacity != clamped {
                spectrumBackgroundOpacity = clamped
            } else {
                defaults.set(clamped, forKey: Self.spectrumBackgroundOpacityDefaultsKey)
            }
        }
    }

    @Published var spectrumBarColor: SpectrumBarColor {
        didSet { defaults.set(spectrumBarColor.rawValue, forKey: Self.spectrumBarColorDefaultsKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = defaults.string(forKey: Self.styleDefaultsKey)
            .flatMap(PlayerMeterStyle.init(rawValue:)) ?? .spectrum
        backlight = defaults.string(forKey: Self.backlightDefaultsKey)
            .flatMap(VUMeterBacklight.init(rawValue:)) ?? .cyan
        barPosition = defaults.string(forKey: Self.barPositionDefaultsKey)
            .flatMap(PlayerBarPosition.init(rawValue:)) ?? .bottom
        spectrumBarColor = defaults.string(forKey: Self.spectrumBarColorDefaultsKey)
            .flatMap(SpectrumBarColor.init(rawValue:)) ?? .automatic
        if defaults.object(forKey: Self.spectrumBackgroundOpacityDefaultsKey) != nil {
            spectrumBackgroundOpacity = min(
                max(
                    defaults.double(forKey: Self.spectrumBackgroundOpacityDefaultsKey),
                    Self.spectrumBackgroundOpacityRange.lowerBound
                ),
                Self.spectrumBackgroundOpacityRange.upperBound
            )
        } else {
            spectrumBackgroundOpacity = Self.defaultSpectrumBackgroundOpacity
        }
    }
}
