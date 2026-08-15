import Combine
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var localizationKey: String {
        switch self {
        case .system: "settings.appearance.system"
        case .light: "settings.appearance.light"
        case .dark: "settings.appearance.dark"
        }
    }
}

@MainActor
final class AppAppearanceSettings: ObservableObject {
    nonisolated static let defaultsKey = "app.appearance.v1"

    @Published var selectedAppearance: AppAppearance {
        didSet {
            if selectedAppearance == .system {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                defaults.set(selectedAppearance.rawValue, forKey: Self.defaultsKey)
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawValue = defaults.string(forKey: Self.defaultsKey),
           let appearance = AppAppearance(rawValue: rawValue) {
            selectedAppearance = appearance
        } else {
            selectedAppearance = .system
        }
    }
}
