import SwiftUI
import UniformTypeIdentifiers

enum MediaOrganizationStatus: String, Codable, Sendable {
    case move
    case unchanged
    case external
    case unavailable

    var titleKey: String { "mediaOrganization.status.\(rawValue)" }
}

struct MediaOrganizationItem: Identifiable, Codable, Sendable {
    var id: String { sourceURL.path }
    var trackIDs: [Track.ID]
    var sourceURL: URL
    var destinationURL: URL
    var expectedSHA256: String
    var status: MediaOrganizationStatus
}

struct MediaOrganizationPreview: Sendable {
    var sourceRootURL: URL
    var destinationRootURL: URL
    var items: [MediaOrganizationItem]

    var moveCount: Int { items.count { $0.status == .move } }
    var unchangedCount: Int { items.count { $0.status == .unchanged } }
    var externalCount: Int { items.count { $0.status == .external } }
    var unavailableCount: Int { items.count { $0.status == .unavailable } }

    func restricted(to trackIDs: Set<Track.ID>) -> MediaOrganizationPreview {
        guard !trackIDs.isEmpty else {
            return MediaOrganizationPreview(
                sourceRootURL: sourceRootURL,
                destinationRootURL: destinationRootURL,
                items: []
            )
        }
        return MediaOrganizationPreview(
            sourceRootURL: sourceRootURL,
            destinationRootURL: destinationRootURL,
            items: items.filter { !trackIDs.isDisjoint(with: $0.trackIDs) }
        )
    }
}

struct MediaOrganizationSummary: Sendable {
    var moved: Int
    var updatedTracks: Int
}

struct MediaOrganizationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var storage: LibraryStorageSettings
    @EnvironmentObject private var libraryProfiles: LibraryProfileSettings
    @State private var preview: MediaOrganizationPreview?
    @State private var isChoosingDestination = false
    @State private var isLoading = true
    @State private var isExecuting = false
    @State private var errorMessage: String?
    @State private var scopedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("mediaOrganization.title")).font(.headline)
                    Text(L10n.text("mediaOrganization.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("mediaOrganization.choose")) {
                    isChoosingDestination = true
                }
                .disabled(isLoading || isExecuting)
            }

            if isLoading {
                HStack { ProgressView(); Text(L10n.text("mediaOrganization.planning")) }
                    .foregroundStyle(.secondary)
            } else if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preview.destinationRootURL.path)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                    HStack(spacing: 18) {
                        Label(L10n.format("mediaOrganization.count.move", preview.moveCount), systemImage: "arrow.right")
                        Label(L10n.format("mediaOrganization.count.unchanged", preview.unchangedCount), systemImage: "checkmark.circle")
                        if preview.externalCount > 0 {
                            Label(L10n.format("mediaOrganization.count.external", preview.externalCount), systemImage: "link")
                        }
                        if preview.unavailableCount > 0 {
                            Label(L10n.format("mediaOrganization.count.unavailable", preview.unavailableCount), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                }
                Divider()
                List(preview.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: symbol(for: item.status))
                            .foregroundStyle(color(for: item.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.sourceURL.lastPathComponent).lineLimit(1)
                            if item.status == .move {
                                Text(item.destinationURL.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(item.sourceURL.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(L10n.text(item.status.titleKey))
                            .font(.caption)
                            .foregroundStyle(color(for: item.status))
                    }
                }
                .listStyle(.inset)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isExecuting { ProgressView(); Text(L10n.text("mediaOrganization.executing")) }
                Spacer()
                Button(L10n.text("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExecuting)
                Button(L10n.text("mediaOrganization.execute")) {
                    Task { await execute() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview?.moveCount == 0 || isLoading || isExecuting)
            }
        }
        .padding(24)
        .frame(width: 820, height: 620)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isExecuting)
        .task { await loadDefaultPreview() }
        .fileImporter(
            isPresented: $isChoosingDestination,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            retainSecurityScope(for: url)
            loadPreview(destination: url)
        }
        .onDisappear { releaseSecurityScope() }
    }

    private func loadDefaultPreview() async {
        let destination = await library.mediaDirectoryURL()
        loadPreview(destination: destination)
    }

    private func loadPreview(destination: URL) {
        isLoading = true
        errorMessage = nil
        Task {
            do { preview = try await library.previewMediaOrganization(destination: destination) }
            catch { preview = nil; errorMessage = error.localizedDescription }
            isLoading = false
        }
    }

    private func execute() async {
        guard let preview else { return }
        isExecuting = true
        errorMessage = nil
        do {
            _ = try await library.executeMediaOrganization(preview)
            if storage.mediaDirectoryURL.standardizedFileURL
                != preview.destinationRootURL.standardizedFileURL {
                try storage.useSelectedDirectory(preview.destinationRootURL)
                libraryProfiles.updateActiveMediaURL(preview.destinationRootURL)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isExecuting = false
    }

    private func retainSecurityScope(for url: URL) {
        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
    }

    private func releaseSecurityScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func symbol(for status: MediaOrganizationStatus) -> String {
        switch status {
        case .move: "arrow.right.circle.fill"
        case .unchanged: "checkmark.circle.fill"
        case .external: "link.circle"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: MediaOrganizationStatus) -> Color {
        switch status {
        case .move: AppTheme.accent
        case .unchanged: .green
        case .external: .secondary
        case .unavailable: .orange
        }
    }
}
