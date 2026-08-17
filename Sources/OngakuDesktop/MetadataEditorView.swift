import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MetadataEditTarget: Identifiable {
    case track(Track)
    case album(id: String, name: String, artist: String, trackIDs: [Track.ID])

    var id: String {
        switch self {
        case .track(let track): "track:\(track.id.uuidString)"
        case .album(let id, _, _, _): "album:\(id)"
        }
    }
}

struct MetadataEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    let target: MetadataEditTarget

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isSelectingArtwork = false
    @State private var selectedArtworkData: Data?
    @State private var selectedArtworkImage: NSImage?
    @State private var hasCustomArtwork = false
    @State private var shouldRemoveCustomArtwork = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, artist, album }

    init(target: MetadataEditTarget) {
        self.target = target
        switch target {
        case .track(let track):
            _title = State(initialValue: track.title)
            _artist = State(initialValue: track.artist)
            _album = State(initialValue: track.album)
        case .album(_, let name, let artist, _):
            _title = State(initialValue: "")
            _artist = State(initialValue: artist)
            _album = State(initialValue: name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text(isTrack ? "metadataEditor.track.title" : "metadataEditor.album.title"))
                    .font(.title2.bold())
                Text(L10n.text(isTrack ? "metadataEditor.track.description" : "metadataEditor.album.description"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: AppTheme.spaceLG) {
                artworkEditor

                VStack(spacing: AppTheme.spaceMD) {
                    if isTrack {
                        field(
                            L10n.text("metadataEditor.field.title"),
                            text: $title,
                            field: .title
                        )
                    }
                    field(
                        L10n.text("metadataEditor.field.artist"),
                        text: $artist,
                        field: .artist
                    )
                    field(
                        L10n.text("metadataEditor.field.album"),
                        text: $album,
                        field: .album
                    )
                }
            }
            .padding(AppTheme.spaceMD)
            .ongakuPanel()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.warning)
            }

            HStack {
                if case .album(_, _, _, let trackIDs) = target {
                    Text(L10n.format("metadataEditor.album.songCount", trackIDs.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.text("metadataEditor.save"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: 660)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            focusedField = isTrack ? .title : .album
            Task {
                hasCustomArtwork = await ArtworkResolver.shared
                    .customArtworkData(for: sourceArtworkSubject) != nil
            }
        }
        .fileImporter(
            isPresented: $isSelectingArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: importArtwork
        )
    }

    private var isTrack: Bool {
        if case .track = target { return true }
        return false
    }

    private var canSave: Bool {
        !artist.trimmedForMetadata.isEmpty
            && !album.trimmedForMetadata.isEmpty
            && (!isTrack || !title.trimmedForMetadata.isEmpty)
    }

    private func field(_ label: String, text: Binding<String>, field: Field) -> some View {
        LabeledContent(label) {
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
                .frame(width: 300)
        }
    }

    private var artworkEditor: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("metadataEditor.artwork.title"))
                .font(.headline)

            Group {
                if let selectedArtworkImage {
                    Image(nsImage: selectedArtworkImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    ArtworkThumbnail(
                        tracks: targetTracks,
                        subject: sourceArtworkSubject,
                        shape: .roundedRectangle,
                        fallbackSymbol: "photo",
                        fallbackLetter: String(album.prefix(1)).uppercased()
                    )
                }
            }
            .frame(width: 144, height: 144)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous))

            Button(L10n.text("metadataEditor.artwork.choose")) {
                isSelectingArtwork = true
            }
            .frame(width: 144)

            Button(L10n.text("metadataEditor.artwork.remove")) {
                selectedArtworkData = nil
                selectedArtworkImage = nil
                shouldRemoveCustomArtwork = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryInk)
            .disabled(!hasCustomArtwork && selectedArtworkData == nil)
            .frame(width: 144)
        }
    }

    private var targetTracks: [Track] {
        switch target {
        case .track(let track): return [track]
        case .album(_, _, _, let trackIDs):
            let ids = Set(trackIDs)
            return library.tracks.filter { ids.contains($0.id) }
        }
    }

    private var sourceArtworkSubject: ArtworkSubject {
        switch target {
        case .track(let track): .album(name: track.album, artist: track.artist)
        case .album(_, let name, let artist, _): .album(name: name, artist: artist)
        }
    }

    private var destinationArtworkSubject: ArtworkSubject {
        .album(name: album.trimmedForMetadata, artist: artist.trimmedForMetadata)
    }

    private func importArtwork(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 12 * 1_024 * 1_024,
                  let image = NSImage(data: data) else {
                errorMessage = L10n.text("metadataEditor.artwork.invalid")
                return
            }
            selectedArtworkData = data
            selectedArtworkImage = image
            shouldRemoveCustomArtwork = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await persistArtworkChange()

            switch target {
            case .track(let track):
                try await library.updateTrackMetadata(
                    id: track.id,
                    title: title.trimmedForMetadata,
                    artist: artist.trimmedForMetadata,
                    album: album.trimmedForMetadata
                )
            case .album(_, _, _, let trackIDs):
                try await library.updateAlbumMetadata(
                    trackIDs: trackIDs,
                    artist: artist.trimmedForMetadata,
                    album: album.trimmedForMetadata
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    private func persistArtworkChange() async throws {
        if let selectedArtworkData {
            try await ArtworkResolver.shared.registerCustomArtwork(
                selectedArtworkData,
                for: destinationArtworkSubject
            )
            if sourceArtworkSubject != destinationArtworkSubject {
                try await ArtworkResolver.shared.removeCustomArtwork(for: sourceArtworkSubject)
            }
        } else if shouldRemoveCustomArtwork {
            try await ArtworkResolver.shared.removeCustomArtwork(for: sourceArtworkSubject)
            if sourceArtworkSubject != destinationArtworkSubject {
                try await ArtworkResolver.shared.removeCustomArtwork(for: destinationArtworkSubject)
            }
        } else {
            try await ArtworkResolver.shared.migrateCustomArtwork(
                from: sourceArtworkSubject,
                to: destinationArtworkSubject
            )
        }
    }
}

private extension String {
    var trimmedForMetadata: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
