import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var locale: Locale? {
        switch self {
        case .system: nil
        default: Locale(identifier: rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .system: L10n.text("settings.language.system")
        case .english: "English"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        }
    }
}

@MainActor
final class AppLanguageSettings: ObservableObject {
    nonisolated static let defaultsKey = "app.displayLanguage.v1"

    @Published var selectedLanguage: AppLanguage {
        didSet {
            if selectedLanguage == .system {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                defaults.set(selectedLanguage.rawValue, forKey: Self.defaultsKey)
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawValue = defaults.string(forKey: Self.defaultsKey),
           let language = AppLanguage(rawValue: rawValue) {
            selectedLanguage = language
        } else {
            selectedLanguage = .system
        }
    }
}
