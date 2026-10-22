// The audit compiles the shipping effect implementations and settings. Only
// these UI/logging dependencies are replaced in the standalone macOS executable.
enum L10n {
    static func tr(_ key: String) -> String { key }
    static func text(_ key: String) -> String { key }
}
enum PlaybackDebugLogger { static func event(_ message: String) {} }
