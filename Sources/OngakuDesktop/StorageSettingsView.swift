import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StorageSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var storage: LibraryStorageSettings
    @State private var isApplyingLocation = false
    @State private var isImportingMusicLibrary = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            HStack(spacing: AppTheme.spaceMD) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(AppTheme.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("settings.storage.title"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.text("settings.storage.subtitle"))
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
                Text(L10n.text("settings.storage.location"))
                    .font(.headline)

                Text(storage.mediaDirectoryURL.path(percentEncoded: false))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                    .padding(AppTheme.spaceMD)
                    .frame(minHeight: 54, alignment: .leading)
                    .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))

                Label(L10n.text(storage.source.localizationKey), systemImage: sourceIcon)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)

                if let musicLibraryURL = storage.musicLibraryURL {
                    Text(musicLibraryURL.path(percentEncoded: false))
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppTheme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(musicLibraryURL.path(percentEncoded: false))
                }
            }

            HStack(spacing: AppTheme.spaceSM) {
                Button(L10n.text("settings.storage.choose")) {
                    chooseDirectory()
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.text("settings.storage.chooseMusicLibrary")) {
                    chooseMusicLibrary()
                }
                .buttonStyle(.bordered)
                .help(storage.musicLibraryURL?.path(percentEncoded: false) ?? L10n.text("settings.storage.musicLibraryHelp"))

                Button(L10n.text("settings.storage.automatic")) {
                    Task {
                        storage.restoreAutomaticLocation()
                        _ = await applyCurrentLocation()
                        resultMessage = nil
                    }
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .disabled(isApplyingLocation || isImportingMusicLibrary)

            if isImportingMusicLibrary {
                HStack(spacing: AppTheme.spaceXS) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("settings.storage.importingMusicLibrary"))
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
            } else if let resultMessage {
                Label(resultMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.good)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Label(L10n.text("settings.storage.safetyNote"), systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = storage.mediaDirectoryURL.deletingLastPathComponent()
        panel.prompt = L10n.text("settings.storage.choosePanelConfirm")
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { return }
            Task { @MainActor in
                do {
                    try storage.useSelectedDirectory(parent)
                    _ = await applyCurrentLocation()
                    resultMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func chooseMusicLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Music", isDirectory: true)
        let musicLibraryType = UTType(filenameExtension: "musiclibrary") ?? .package
        panel.allowedContentTypes = [.package, musicLibraryType]
        panel.prompt = L10n.text("settings.storage.choosePanelConfirm")
        panel.begin { response in
            guard response == .OK, let libraryURL = panel.url else { return }
            Task { @MainActor in
                do {
                    try storage.useAppleMusicLibrary(libraryURL)
                    guard let musicLibraryMediaURL = storage.musicLibraryMediaURL else { return }
                    isImportingMusicLibrary = true
                    defer { isImportingMusicLibrary = false }
                    let summary = await library.importAppleMusicMediaFolder(
                        musicLibraryMediaURL,
                        excluding: storage.mediaDirectoryURL
                    )
                    resultMessage = L10n.format(
                        "settings.storage.musicLibraryImportResult",
                        summary.discovered,
                        summary.imported,
                        summary.relinked,
                        summary.issues
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func applyCurrentLocation() async -> Bool {
        isApplyingLocation = true
        defer { isApplyingLocation = false }
        do {
            try await library.setMediaDirectory(storage.mediaDirectoryURL)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var sourceIcon: String {
        switch storage.source {
        case .automaticAppleMusic: "music.note"
        case .selectedAppleMusicLibrary: "music.note.list"
        case .applicationSupport: "internaldrive"
        case .userSelected: "folder.badge.gearshape"
        }
    }
}
