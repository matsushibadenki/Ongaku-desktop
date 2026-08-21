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
