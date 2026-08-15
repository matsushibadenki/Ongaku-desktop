import Foundation

enum L10n {
    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        let baseBundle = Bundle.module
#else
        let baseBundle = Bundle.main
#endif
        guard let language = UserDefaults.standard.string(forKey: AppLanguageSettings.defaultsKey),
              let path = baseBundle.path(forResource: language, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return baseBundle
        }
        return localizedBundle
    }

    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: resourceBundle, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
