import SwiftUI
import UniformTypeIdentifiers

struct SharedFolderMigrationRow: Identifiable, Sendable {
    var id: String { sourceURL.path }
    var sourceURL: URL
    var relativePath: String
    var sha256: String?
    var status: LegacyLibraryTrackStatus
}

struct SharedFolderMigrationPreview: Sendable {
    var rootURL: URL
    var rows: [SharedFolderMigrationRow]

    var readyCount: Int { rows.count { $0.status == .ready } }
    var registeredCount: Int { rows.count { $0.status == .alreadyRegistered } }
    var unavailableCount: Int { rows.count { $0.status == .missing } }
}

struct SharedFolderMigrationSummary: Sendable {
    var imported: Int
    var linkedExisting: Int
    var issues: Int
}

enum SharedFolderMigrationError: LocalizedError {
    case noAudioFiles

    var errorDescription: String? { L10n.text("sharedFolderMigration.error.noAudio") }
}

struct SharedFolderMigrationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var preview: SharedFolderMigrationPreview?
    @State private var isChoosingFolder = false
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var scopedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("sharedFolderMigration.title")).font(.headline)
                    Text(L10n.text("sharedFolderMigration.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("sharedFolderMigration.choose")) {
                    isChoosingFolder = true
                }
                .disabled(isLoading || isImporting)
            }

            if isLoading {
                HStack {
                    ProgressView()
                    Text(L10n.text("sharedFolderMigration.reading"))
                }
                .foregroundStyle(.secondary)
            } else if let preview {
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.rootURL.lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 18) {
                        Label(L10n.format("libraryMigration.count.ready", preview.readyCount), systemImage: "square.and.arrow.down")
                        Label(L10n.format("libraryMigration.count.registered", preview.registeredCount), systemImage: "checkmark.circle")
                        if preview.unavailableCount > 0 {
                            Label(L10n.format("libraryMigration.count.unavailable", preview.unavailableCount), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                }
                Divider()
                List(preview.rows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: symbol(for: row.status))
                            .foregroundStyle(color(for: row.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.sourceURL.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                            Text(row.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(L10n.text(row.status.titleKey))
                            .font(.caption)
                            .foregroundStyle(color(for: row.status))
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    L10n.text("sharedFolderMigration.empty.title"),
                    systemImage: "folder.badge.plus",
                    description: Text(L10n.text("sharedFolderMigration.empty.description"))
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
                if isImporting {
                    ProgressView()
                    Text(L10n.text("sharedFolderMigration.importing"))
                }
                Spacer()
                Button(L10n.text("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button(L10n.text("sharedFolderMigration.import")) {
                    Task { await performImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview?.readyCount == 0 || isLoading || isImporting)
            }
        }
        .padding(24)
        .frame(width: 760, height: 600)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isImporting)
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            retainSecurityScope(for: url)
            loadPreview(url)
        }
        .onDisappear { releaseSecurityScope() }
    }

    private func retainSecurityScope(for url: URL) {
        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
    }

    private func releaseSecurityScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func loadPreview(_ url: URL) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                preview = try await library.previewSharedFolder(at: url)
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
            _ = try await library.importSharedFolder(preview)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }

    private func symbol(for status: LegacyLibraryTrackStatus) -> String {
        switch status {
        case .ready: "square.and.arrow.down"
        case .alreadyRegistered: "checkmark.circle.fill"
        case .missing: "exclamationmark.triangle"
        case .unsupported: "nosign"
        }
    }

    private func color(for status: LegacyLibraryTrackStatus) -> Color {
        switch status {
        case .ready: AppTheme.accent
        case .alreadyRegistered: .green
        case .missing, .unsupported: .orange
        }
    }
}
