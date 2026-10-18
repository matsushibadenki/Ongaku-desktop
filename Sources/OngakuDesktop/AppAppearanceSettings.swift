import Combine
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case pink, purple, green, beige

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .pink, .purple, .green, .beige: .light
        case .dark: .dark
        }
    }

    var pastelHex: UInt32? {
        switch self {
        case .pink: 0xfbeefa
        case .purple: 0xeeecfe
        case .green: 0xe1fff4
        case .beige: 0xfaf7e3
        default: nil
        }
    }
    var accentHex: UInt32? {
        switch self {
        case .pink: 0xa83f79
        case .purple: 0x7051b4
        case .green: 0x24765b
        case .beige: 0x856122
        default: nil
        }
    }
    /// Opaque, same-hue highlights keep the colored enclosure visibly colored.
    var meterFrameColors: [Color] {
        let values: [UInt32] = switch self {
        case .pink: [0xfce3f2, 0xf5d0e6, 0xebbedb]
        case .purple: [0xeee7fd, 0xded3f9, 0xcfc0f0]
        case .green: [0xddf8ea, 0xc7eed9, 0xafe1c6]
        case .beige: [0xfaf2d8, 0xf0e5be, 0xe5d5a6]
        default: [0xf4f4f4, 0xe6e6e6, 0xd6d6d6]
        }
        return values.map(Self.color)
    }
    var pastelColor: Color? { pastelHex.map(Self.color) }
    var accentColor: Color? { accentHex.map(Self.color) }
    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }

    var localizationKey: String {
        switch self {
        case .system: "settings.appearance.system"
        case .light: "settings.appearance.light"
        case .dark: "settings.appearance.dark"
        case .pink, .purple, .green, .beige: "settings.appearance.\(rawValue)"
        }
    }
}

@MainActor
final class AppAppearanceSettings: ObservableObject {
    nonisolated static let defaultsKey = "app.appearance.v1"

    @Published var selectedAppearance: AppAppearance {
        didSet {
            DesktopAppearancePalette.shared.selection = selectedAppearance
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
        DesktopAppearancePalette.shared.selection = selectedAppearance
    }
}

enum TrackTableColumn: String, CaseIterable, Identifiable, Sendable {
    case artist
    case album
    case duration
    case health

    var id: String { rawValue }
    var localizationKey: String { "column.\(rawValue)" }
}

enum TrackTableSortField: String, CaseIterable, Sendable {
    case title
    case artist
    case album
}

@MainActor
final class TrackTableSettings: ObservableObject {
    nonisolated static let visibleColumnsKey = "library.table.visibleColumns.v1"
    nonisolated static let sortFieldKey = "library.table.sortField.v1"
    nonisolated static let sortAscendingKey = "library.table.sortAscending.v1"

    @Published var visibleColumns: Set<TrackTableColumn> {
        didSet {
            defaults.set(visibleColumns.map(\.rawValue).sorted(), forKey: Self.visibleColumnsKey)
        }
    }
    @Published var sortField: TrackTableSortField {
        didSet { defaults.set(sortField.rawValue, forKey: Self.sortFieldKey) }
    }
    @Published var sortAscending: Bool {
        didSet { defaults.set(sortAscending, forKey: Self.sortAscendingKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: Self.visibleColumnsKey) {
            visibleColumns = Set(saved.compactMap(TrackTableColumn.init(rawValue:)))
        } else {
            visibleColumns = Set(TrackTableColumn.allCases)
        }
        sortField = defaults.string(forKey: Self.sortFieldKey)
            .flatMap(TrackTableSortField.init(rawValue:)) ?? .title
        sortAscending = defaults.object(forKey: Self.sortAscendingKey) as? Bool ?? true
    }

    func isVisible(_ column: TrackTableColumn) -> Bool {
        visibleColumns.contains(column)
    }

    func binding(for column: TrackTableColumn) -> Binding<Bool> {
        Binding(
            get: { self.visibleColumns.contains(column) },
            set: { visible in
                if visible { self.visibleColumns.insert(column) }
                else { self.visibleColumns.remove(column) }
            }
        )
    }
}

/// Observable bridge for the shared design tokens. Reading a token inside a
/// SwiftUI body tracks palette changes without replacing navigation/view state.
@MainActor @Observable
final class DesktopAppearancePalette {
    static let shared = DesktopAppearancePalette()
    var selection: AppAppearance = .system
}
