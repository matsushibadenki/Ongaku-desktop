import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StorageSettingsView: View {
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlaybackController
  @EnvironmentObject private var libraryProfiles: LibraryProfileSettings
  @EnvironmentObject private var storage: LibraryStorageSettings
  @State private var isApplyingLocation = false
  @State private var isImportingMusicLibrary = false
  @State private var isRegisteringDroppedFolder = false
  @State private var isFolderDropTargeted = false
  @State private var isClearingLibrary = false
  @State private var recoveryCopyTask: Task<Void, Never>?
  @State private var isCreatingRecoveryCopy = false
  @State private var isRescuingCatalog = false
  @State private var isShowingRescueConfirmation = false
  @State private var isExportingRecovery = false
  @State private var isShowingClearConfirmation = false
  @State private var resultMessage: String?
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
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

          VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(storage.mediaDirectoryURL.path(percentEncoded: false))
              .font(.system(.callout, design: .monospaced))
              .foregroundStyle(AppTheme.ink)
              .textSelection(.enabled)

            Label(
              L10n.text("settings.storage.dropFolderHint"),
              systemImage: isFolderDropTargeted ? "arrow.down.circle.fill" : "folder.badge.plus"
            )
            .font(.caption)
            .foregroundStyle(isFolderDropTargeted ? AppTheme.accent : AppTheme.secondaryInk)
          }
          .padding(AppTheme.spaceMD)
          .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
          .background(
            isFolderDropTargeted ? AppTheme.accent.opacity(0.1) : AppTheme.raised,
            in: RoundedRectangle(cornerRadius: 8)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(isFolderDropTargeted ? AppTheme.accent : .clear, lineWidth: 2)
          }
          .contentShape(RoundedRectangle(cornerRadius: 8))
          .dropDestination(for: URL.self) { urls, _ in
            acceptDroppedFolder(urls)
          } isTargeted: { isTargeted in
            isFolderDropTargeted = isTargeted
          }

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
          .ongakuProminentButton()

          Button(L10n.text("settings.storage.chooseMusicLibrary")) {
            chooseMusicLibrary()
          }
          .buttonStyle(.bordered)
          .help(
            storage.musicLibraryURL?.path(percentEncoded: false)
              ?? L10n.text("settings.storage.musicLibraryHelp"))

          Button(L10n.text("settings.storage.automatic")) {
            Task {
              isApplyingLocation = true
              defer { isApplyingLocation = false }
              do {
                try await storage.activateAutomaticLocation { url in
                  try await library.openStorageDirectory(url)
                }
                try finishStorageSwitch()
              } catch { errorMessage = error.localizedDescription }
            }
          }
          .buttonStyle(.bordered)

          Spacer()
        }
        .disabled(isStorageOperationInProgress)

        HStack(spacing: AppTheme.spaceSM) {
          Button(L10n.text("storage.migration.retry")) {
            NotificationCenter.default.post(name: .requestLibraryRecovery, object: nil)
          }
          .buttonStyle(.bordered)
          .disabled(isStorageOperationInProgress)
          Button(L10n.text("settings.storage.exportRecovery")) {
            exportRecoverySnapshot()
          }
          .buttonStyle(.bordered)
          .disabled(isStorageOperationInProgress)
          .help(L10n.text("settings.storage.exportRecovery.help"))
          Button {
            isShowingRescueConfirmation = true
          } label: {
            Image(systemName: "arrow.uturn.backward.circle")
          }
          .buttonStyle(.bordered)
          .disabled(isStorageOperationInProgress)
          .help(L10n.text("settings.storage.rescueCatalog"))
          .accessibilityLabel(L10n.text("settings.storage.rescueCatalog"))
          Menu {
            Button(L10n.text("settings.storage.recoveryCopy.create")) { chooseRecoveryCatalog() }
            Button(L10n.text("settings.storage.recoveryCopy.resume")) { chooseRecoveryDestination(manifest: nil) }
          } label: {
            Image(systemName: "square.on.square")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .disabled(isStorageOperationInProgress)
          .help(L10n.text("settings.storage.recoveryCopy.help"))
          .accessibilityLabel(L10n.text("settings.storage.recoveryCopy.create"))
          if isCreatingRecoveryCopy {
            ProgressView().controlSize(.small)
            Button(L10n.text("common.cancel")) { recoveryCopyTask?.cancel() }
          }
          Image(systemName: "info.circle")
            .foregroundStyle(AppTheme.secondaryInk)
            .help(L10n.text("storage.migration.sameFolder"))
            .accessibilityLabel(L10n.text("storage.migration.sameFolder"))
        }

        if isImportingMusicLibrary || isRegisteringDroppedFolder {
          HStack(spacing: AppTheme.spaceXS) {
            ProgressView()
              .controlSize(.small)
            Text(
              L10n.text(
                isRegisteringDroppedFolder
                  ? "settings.storage.registeringDroppedFolder"
                  : "settings.storage.importingMusicLibrary"
              )
            )
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

        Divider()

        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
          Text(L10n.text("settings.storage.clearTitle"))
            .font(.headline)

          Text(L10n.text("settings.storage.clearDescription"))
            .font(.callout)
            .foregroundStyle(AppTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)

          Button(role: .destructive) {
            isShowingClearConfirmation = true
          } label: {
            HStack(spacing: AppTheme.spaceXS) {
              if isClearingLibrary {
                ProgressView()
                  .controlSize(.small)
              }
              Text(L10n.text("settings.storage.clearButton"))
            }
          }
          .buttonStyle(.bordered)
          .tint(AppTheme.danger)
          .disabled(
            library.tracks.isEmpty
              || isClearingLibrary
              || isStorageOperationInProgress
          )
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(AppTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, AppTheme.spaceMD)
      .background {
        GeometryReader { proxy in
          Color.clear.preference(
            key: PreferencesContentHeightPreferenceKey.self,
            value: proxy.size.height
          )
        }
      }
    }
    .scrollIndicators(.automatic)
    .alert(L10n.text("settings.storage.rescueCatalog"), isPresented: $isShowingRescueConfirmation) {
      Button(L10n.text("common.cancel"), role: .cancel) {}
      Button(L10n.text("settings.storage.rescueCatalog.confirm"), role: .destructive) {
        rescueCatalog()
      }
    } message: {
      Text(L10n.text("settings.storage.rescueCatalog.message"))
    }
    .alert(
      L10n.text("settings.storage.clearConfirmationTitle"),
      isPresented: $isShowingClearConfirmation
    ) {
      Button(L10n.text("common.cancel"), role: .cancel) {}
      Button(L10n.text("settings.storage.clearConfirmationButton"), role: .destructive) {
        clearAllRegistrations()
      }
    } message: {
      Text(L10n.format("settings.storage.clearConfirmationMessage", library.tracks.count))
    }
  }

  @MainActor
  private func acceptDroppedFolder(_ urls: [URL]) -> Bool {
    guard !isStorageOperationInProgress, urls.count == 1, let folderURL = urls.first else {
      errorMessage = L10n.text("settings.storage.error.dropOneFolder")
      return false
    }
    guard
      let values = try? folderURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory == true,
      values.isSymbolicLink != true
    else {
      errorMessage = L10n.text("settings.storage.error.dropFolderOnly")
      return false
    }

    guard let media = mediaFolderForSelection(folderURL) else { return false }
    registerDroppedFolder(media)
    return true
  }

  @MainActor
  private func registerDroppedFolder(_ folderURL: URL) {
    isRegisteringDroppedFolder = true
    resultMessage = nil
    errorMessage = nil

    Task { @MainActor in
      defer { isRegisteringDroppedFolder = false }
      do {
        try await storage.activateDirectory(folderURL) { url in
          try await library.openStorageDirectory(url)
        }
        try finishStorageSwitch()
        let summary = await library.registerMediaFolderInPlace(storage.mediaDirectoryURL)
        resultMessage = L10n.format(
          "settings.storage.folderRegistrationResult",
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

  @MainActor
  private func chooseRecoveryCatalog() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json]
    panel.directoryURL = libraryProfiles.activeProfile.catalogURL
    panel.message = L10n.text("settings.storage.recoveryCopy.source")
    panel.begin { response in
      guard response == .OK, let manifest = panel.url else { return }
      chooseRecoveryDestination(manifest: manifest)
    }
  }

  @MainActor
  private func chooseRecoveryDestination(manifest: URL?) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = manifest != nil
    panel.allowsMultipleSelection = false
    panel.message = L10n.text(manifest == nil ? "settings.storage.recoveryCopy.resumeHelp" : "settings.storage.recoveryCopy.help")
    let missing = NSButton(checkboxWithTitle: L10n.text("settings.storage.recoveryCopy.keepMissing"), target: nil, action: nil)
    missing.state = .off
    missing.sizeToFit()
    panel.accessoryView = missing
    panel.begin { response in
      guard response == .OK, let folder = panel.url else { return }
      guard !isStorageOperationInProgress else { return }
      let origin = libraryProfiles.activeProfile
      isCreatingRecoveryCopy = true
      resultMessage = nil
      errorMessage = nil
      recoveryCopyTask = Task { @MainActor in
        defer { isCreatingRecoveryCopy = false; recoveryCopyTask = nil }
        let sourceAccess = manifest?.startAccessingSecurityScopedResource() == true
        let destinationAccess = folder.startAccessingSecurityScopedResource()
        defer {
          if sourceAccess { manifest?.stopAccessingSecurityScopedResource() }
          if destinationAccess { folder.stopAccessingSecurityScopedResource() }
        }
        do {
          let media: URL
          if let manifest {
            let source = LibraryRepository(rootURL: origin.catalogURL, mediaURL: origin.mediaURL)
            media = try await source.prepareRecoveryCopy(from: manifest, in: folder, allowMissing: missing.state == .on)
          } else { media = folder }
          let layout = PortableLibraryStorage(mediaURL: media)
          let target = LibraryRepository(rootURL: layout.rootURL, mediaURL: media)
          let result = try await target.resumeRecoveryCopy(allowMissing: missing.state == .on)
          try Task.checkCancellation()
          guard libraryProfiles.activeProfile.id == origin.id, library.isUsingCatalog(at: origin.catalogURL) else {
            resultMessage = L10n.format("settings.storage.recoveryCopy.notOpened", media.path)
            return
          }
          player.clearCurrentTrack()
          try await storage.activateDirectory(media) { url in try await library.openRecoveryCopy(url, expectedLibraryID: result.libraryID) }
          try finishStorageSwitch()
          resultMessage = L10n.format("settings.storage.recoveryCopy.success", result.trackCount, result.missingTrackCount, result.derivedHashCount, media.path)
        } catch { errorMessage = error.localizedDescription }
      }
    }
  }

  @MainActor
  private func rescueCatalog() {
    guard !isStorageOperationInProgress else { return }
    isRescuingCatalog = true
    resultMessage = nil
    errorMessage = nil
    player.clearCurrentTrack()
    Task { @MainActor in
      defer { isRescuingCatalog = false }
      do {
        let backup = try await library.rescueDamagedLibraryJournal()
        player.restorePlaybackQueue(library.playbackQueue, tracks: library.tracks)
        resultMessage = L10n.format("settings.storage.rescueCatalog.success", backup.path)
      } catch { errorMessage = error.localizedDescription }
    }
  }

  @MainActor
  private func exportRecoverySnapshot() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = L10n.text("settings.storage.exportRecovery.help")
    panel.begin { response in
      guard response == .OK, let destination = panel.url else { return }
      Task { @MainActor in
        isExportingRecovery = true
        resultMessage = nil
        errorMessage = nil
        defer { isExportingRecovery = false }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        do {
          let profile = libraryProfiles.activeProfile
          let repository = LibraryRepository(rootURL: profile.catalogURL, mediaURL: profile.mediaURL)
          let result = try await repository.exportRecoverySnapshot(to: destination)
          resultMessage = L10n.format("settings.storage.exportRecovery.success", result.path)
        } catch {
          errorMessage = error.localizedDescription
        }
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
      guard response == .OK, let selected = panel.url,
        let parent = mediaFolderForSelection(selected) else { return }
      Task { @MainActor in
        isApplyingLocation = true
        defer { isApplyingLocation = false }
        do {
          let catalog = PortableLibraryStorage(mediaURL: parent).rootURL
          let hadCatalog = ["library-v1.json", "library-v1.backup.json"].contains {
            FileManager.default.fileExists(atPath: catalog.appendingPathComponent($0).path)
          }
          try await storage.activateDirectory(parent) { url in
            try await library.openStorageDirectory(url)
          }
          try finishStorageSwitch()
          if !hadCatalog {
            let summary = await library.registerMediaFolderInPlace(storage.mediaDirectoryURL)
            if case .failed(let message) = library.activity {
              errorMessage = message
            } else {
              resultMessage = L10n.format(
                "settings.storage.folderRegistrationResult",
                summary.discovered, summary.imported, summary.relinked, summary.issues
              )
            }
          }
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  @MainActor
  private func mediaFolderForSelection(_ selected: URL) -> URL? {
    guard selected.lastPathComponent == PortableLibraryStorage.directoryName else { return selected }
    let media = selected.deletingLastPathComponent().standardizedFileURL
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = media
    panel.message = L10n.text("storage.migration.authorizeMediaFolder")
    guard panel.runModal() == .OK, let granted = panel.url,
          granted.standardizedFileURL == media else { return nil }
    return granted
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
        isImportingMusicLibrary = true
        defer { isImportingMusicLibrary = false }
        do {
          guard let mediaURL = try await resolveMusicMediaDirectory(for: libraryURL) else { return }
          try await storage.activateAppleMusicLibrary(libraryURL, authorizedMediaURL: mediaURL) { url in
            try await library.openStorageDirectory(url)
          }
          try finishStorageSwitch()
          guard let musicLibraryMediaURL = storage.musicLibraryMediaURL else { return }
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
  private func resolveMusicMediaDirectory(for libraryURL: URL) async throws -> URL? {
    let didAccess = libraryURL.startAccessingSecurityScopedResource()
    defer { if didAccess { libraryURL.stopAccessingSecurityScopedResource() } }
    guard libraryURL.pathExtension.lowercased() == "musiclibrary" else {
      throw AppleMusicSettingsReader.AppleMusicLibraryError.invalidPackage
    }
    let media = try? AppleMusicSettingsReader.mediaFolder(forMusicLibrary: libraryURL)
    if let media,
       FileManager.default.isReadableFile(atPath: media.path),
       FileManager.default.isWritableFile(atPath: media.path) {
      return media
    }

    // A package selection does not grant access to a sibling Media folder on an external disk.
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.directoryURL = media ?? libraryURL.deletingLastPathComponent()
    panel.message = L10n.text("settings.storage.authorizeMusicMedia")
    panel.prompt = L10n.text("settings.storage.choosePanelConfirm")
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }

  @MainActor
  private func finishStorageSwitch() throws {
    try libraryProfiles.openExistingLibraryAfterRecoveryConfirmation(at: storage.mediaDirectoryURL)
    player.clearCurrentTrack()
    player.restorePlaybackQueue(library.playbackQueue, tracks: library.tracks)
    errorMessage = nil
    resultMessage = L10n.text("status.storageChanged")
  }

  @MainActor
  private func clearAllRegistrations() {
    guard !isClearingLibrary else { return }
    isClearingLibrary = true
    resultMessage = nil
    errorMessage = nil

    Task { @MainActor in
      defer { isClearingLibrary = false }
      do {
        try await library.clearAllRegistrations()
        player.clearCurrentTrack()
        resultMessage = L10n.text("settings.storage.clearSuccess")
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private var sourceIcon: String {
    switch storage.source {
    case .musicDirectory: "music.note.house"
    case .automaticAppleMusic: "music.note"
    case .selectedAppleMusicLibrary: "music.note.list"
    case .applicationSupport: "internaldrive"
    case .userSelected: "folder.badge.gearshape"
    }
  }

  private var isStorageOperationInProgress: Bool {
    isApplyingLocation || isImportingMusicLibrary || isRegisteringDroppedFolder || isClearingLibrary || isExportingRecovery || isRescuingCatalog || isCreatingRecoveryCopy
      || library.isSwitchingLibrary
      || library.activity == .importing || library.activity == .verifying || library.activity == .relinking
  }
}
