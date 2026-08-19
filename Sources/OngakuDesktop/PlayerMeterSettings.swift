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

@MainActor
final class PlayerMeterSettings: ObservableObject {
    nonisolated static let styleDefaultsKey = "player.meter.style.v1"
    nonisolated static let backlightDefaultsKey = "player.meter.backlight.v1"
    nonisolated static let barPositionDefaultsKey = "player.bar.position.v1"

    @Published var style: PlayerMeterStyle {
        didSet { defaults.set(style.rawValue, forKey: Self.styleDefaultsKey) }
    }

    @Published var backlight: VUMeterBacklight {
        didSet { defaults.set(backlight.rawValue, forKey: Self.backlightDefaultsKey) }
    }

    @Published var barPosition: PlayerBarPosition {
        didSet { defaults.set(barPosition.rawValue, forKey: Self.barPositionDefaultsKey) }
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
    }
}
