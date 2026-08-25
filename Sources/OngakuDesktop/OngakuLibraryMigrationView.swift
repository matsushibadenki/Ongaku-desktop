import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct OngakuLibraryMigrationRow: Identifiable, Sendable {
    var id: Track.ID { track.id }
    var track: Track
    var status: LegacyLibraryTrackStatus
}

struct OngakuLibraryMigrationPreview: Sendable {
    var manifestURL: URL
    var document: LibraryDocument
    var rows: [OngakuLibraryMigrationRow]

    var readyCount: Int { rows.count { $0.status == .ready } }
    var registeredCount: Int { rows.count { $0.status == .alreadyRegistered } }
    var missingCount: Int { rows.count { $0.status == .missing } }
    var unsupportedCount: Int { rows.count { $0.status == .unsupported } }
}

struct OngakuLibraryMigrationSummary: Sendable {
    var imported: Int
    var linkedExisting: Int
    var playlists: Int
    var folders: Int
    var issues: Int
}

enum OngakuLibraryMigrationError: LocalizedError, Equatable {
    case manifestNotFound
    case sameLibrary
    case noTracks

    var errorDescription: String? {
        switch self {
        case .manifestNotFound: L10n.text("ongakuMigration.error.manifestNotFound")
        case .sameLibrary: L10n.text("ongakuMigration.error.sameLibrary")
        case .noTracks: L10n.text("ongakuMigration.error.noTracks")
        }
    }
}

struct OngakuLibraryMigrationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var preview: OngakuLibraryMigrationPreview?
    @State private var isChoosingSource = false
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.trianglehead.merge")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("ongakuMigration.title")).font(.headline)
                    Text(L10n.text("ongakuMigration.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("ongakuMigration.choose")) { isChoosingSource = true }
                    .disabled(isLoading || isImporting)
            }

            if isLoading {
                HStack { ProgressView(); Text(L10n.text("ongakuMigration.reading")) }
                    .foregroundStyle(.secondary)
            } else if let preview {
                summary(preview)
                Divider()
                List(preview.rows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: statusSymbol(row.status))
                            .foregroundStyle(statusColor(row.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.track.title).lineLimit(1)
                            Text("\(row.track.artist) — \(row.track.album)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(L10n.text(row.status.titleKey))
                            .font(.caption)
                            .foregroundStyle(statusColor(row.status))
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    L10n.text("ongakuMigration.empty.title"),
                    systemImage: "externaldrive.badge.plus",
                    description: Text(L10n.text("ongakuMigration.empty.description"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isImporting { ProgressView(); Text(L10n.text("ongakuMigration.importing")) }
                Spacer()
                Button(L10n.text("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button(L10n.text("ongakuMigration.import")) {
                    Task { await performImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasImportableTracks || isLoading || isImporting)
            }
        }
        .padding(24)
        .frame(width: 760, height: 600)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isImporting)
        .fileImporter(
            isPresented: $isChoosingSource,
            allowedContentTypes: [.folder, .json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            loadPreview(url)
        }
    }

    private func summary(_ preview: OngakuLibraryMigrationPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.manifestURL.deletingLastPathComponent().lastPathComponent)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 18) {
                Label(L10n.format("libraryMigration.count.ready", preview.readyCount), systemImage: "square.and.arrow.down")
                Label(L10n.format("libraryMigration.count.registered", preview.registeredCount), systemImage: "checkmark.circle")
                Label(L10n.format("libraryMigration.count.playlists", preview.document.playlists.count), systemImage: "music.note.list")
                Label(L10n.format("ongakuMigration.count.folders", preview.document.playlistFolders.count), systemImage: "folder")
                if preview.missingCount + preview.unsupportedCount > 0 {
                    Label(
                        L10n.format("libraryMigration.count.unavailable", preview.missingCount + preview.unsupportedCount),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }

    private func loadPreview(_ url: URL) {
        isLoading = true
        errorMessage = nil
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                preview = try await library.previewOngakuLibrary(at: url)
            } catch {
                preview = nil
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func performImport() async {
        guard let preview else { return }
        isImporting = true
        errorMessage = nil
        do {
            _ = try await library.importOngakuLibrary(preview)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }

    private var hasImportableTracks: Bool {
        guard let preview else { return false }
        return preview.readyCount + preview.registeredCount > 0
    }

    private func statusSymbol(_ status: LegacyLibraryTrackStatus) -> String {
        switch status {
        case .ready: "square.and.arrow.down"
        case .alreadyRegistered: "checkmark.circle.fill"
        case .missing: "questionmark.folder"
        case .unsupported: "nosign"
        }
    }

    private func statusColor(_ status: LegacyLibraryTrackStatus) -> Color {
        switch status {
        case .ready: AppTheme.accent
        case .alreadyRegistered: .green
        case .missing, .unsupported: .orange
        }
    }
}
