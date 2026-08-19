import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MetadataEditTarget: Identifiable {
    case track(Track)
    case album(id: UUID, name: String, artist: String, tracks: [Track])
    case artist(id: UUID, name: String, trackIDs: [Track.ID])

    var id: String {
        switch self {
        case .track(let track): "track:\(track.id.uuidString)"
        case .album(let id, _, _, _): "album:\(id)"
        case .artist(let id, _, _): "artist:\(id)"
        }
    }
}

private struct MetadataFormState {
    var title = ""
    var artist = ""
    var artistSortName = ""
    var album = ""
    var albumSortName = ""
    var albumArtist = ""
    var albumArtistSortName = ""
    var composer = ""
    var composerSortName = ""
    var grouping = ""
    var genre = ""
    var releaseYear = ""
    var trackNumber = ""
    var trackCount = ""
    var discNumber = ""
    var discCount = ""
    var isCompilation = false
    var rating = 0
    var playCount = "0"
    var comments = ""

    init(track: Track? = nil) {
        guard let track else { return }
        title = track.title
        artist = track.artist
        artistSortName = track.artistSortName
        album = track.album
        albumSortName = track.albumSortName
        albumArtist = track.albumArtist
        albumArtistSortName = track.albumArtistSortName
        composer = track.composer
        composerSortName = track.composerSortName
        grouping = track.grouping
        genre = track.genre
        releaseYear = track.releaseYear.map(String.init) ?? ""
        trackNumber = track.trackNumber.map(String.init) ?? ""
        trackCount = track.trackCount.map(String.init) ?? ""
        discNumber = track.discNumber.map(String.init) ?? ""
        discCount = track.discCount.map(String.init) ?? ""
        isCompilation = track.isCompilation
        rating = track.rating
        playCount = String(track.playCount)
        comments = track.comments
    }

    var values: TrackMetadataValues {
        TrackMetadataValues(
            title: title.trimmedForMetadata,
            artist: artist.trimmedForMetadata,
            artistSortName: artistSortName.trimmedForMetadata,
            album: album.trimmedForMetadata,
            albumSortName: albumSortName.trimmedForMetadata,
            albumArtist: albumArtist.trimmedForMetadata,
            albumArtistSortName: albumArtistSortName.trimmedForMetadata,
            composer: composer.trimmedForMetadata,
            composerSortName: composerSortName.trimmedForMetadata,
            grouping: grouping.trimmedForMetadata,
            genre: genre.trimmedForMetadata,
            releaseYear: positiveInteger(releaseYear),
            trackNumber: positiveInteger(trackNumber),
            trackCount: positiveInteger(trackCount),
            discNumber: positiveInteger(discNumber),
            discCount: positiveInteger(discCount),
            isCompilation: isCompilation,
            rating: min(max(rating, 0), 5),
            playCount: max(0, Int(playCount) ?? 0),
            comments: comments.trimmedForMetadata
        )
    }

    private func positiveInteger(_ value: String) -> Int? {
        guard let parsed = Int(value), parsed > 0 else { return nil }
        return parsed
    }
}

struct MetadataEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let target: MetadataEditTarget

    @State private var form: MetadataFormState
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isSelectingArtwork = false
    @State private var selectedArtworkData: Data?
    @State private var selectedArtworkImage: NSImage?
    @State private var hasCustomArtwork = false
    @State private var shouldRemoveCustomArtwork = false

    init(target: MetadataEditTarget) {
        self.target = target
        switch target {
        case .track(let track):
            _form = State(initialValue: MetadataFormState(track: track))
        case .album(_, let name, let artist, let tracks):
            var state = MetadataFormState(track: tracks.first)
            state.artist = artist
            state.album = name
            _form = State(initialValue: state)
        case .artist(_, let name, _):
            var state = MetadataFormState()
            state.artist = name
            _form = State(initialValue: state)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text(titleKey)).font(.title2.bold())
                Text(L10n.text(descriptionKey))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: AppTheme.spaceLG) {
                artworkEditor
                if isArtist {
                    metadataField("metadataEditor.field.artist", text: $form.artist)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
                            detailsSection
                            organizationSection
                            playbackSection
                        }
                        .padding(.trailing, AppTheme.spaceSM)
                    }
                    .frame(maxHeight: 520)
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
                if !isTrack {
                    Text(
                        L10n.format(
                            isArtist ? "metadataEditor.artist.songCount" : "metadataEditor.album.songCount",
                            targetTracks.count
                        )
                    )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text(L10n.text("metadataEditor.save")) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: isArtist ? 660 : 900, height: isArtist ? nil : 720)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
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

    private var detailsSection: some View {
        metadataSection("metadataEditor.section.details") {
            if isTrack { metadataField("metadataEditor.field.title", text: $form.title) }
            metadataField("metadataEditor.field.artist", text: $form.artist)
            metadataField("metadataEditor.field.artistSortName", text: $form.artistSortName)
            metadataField("metadataEditor.field.album", text: $form.album)
            metadataField("metadataEditor.field.albumSortName", text: $form.albumSortName)
            metadataField("metadataEditor.field.albumArtist", text: $form.albumArtist)
            metadataField(
                "metadataEditor.field.albumArtistSortName",
                text: $form.albumArtistSortName
            )
            metadataField("metadataEditor.field.composer", text: $form.composer)
            metadataField("metadataEditor.field.composerSortName", text: $form.composerSortName)
        }
    }

    private var organizationSection: some View {
        metadataSection("metadataEditor.section.organization") {
            metadataField("metadataEditor.field.grouping", text: $form.grouping)
            metadataField("metadataEditor.field.genre", text: $form.genre)
            metadataField("metadataEditor.field.releaseYear", text: $form.releaseYear)
            if isTrack {
                numberPair(
                    "metadataEditor.field.trackNumber",
                    number: $form.trackNumber,
                    total: $form.trackCount
                )
            }
            numberPair(
                "metadataEditor.field.discNumber",
                number: $form.discNumber,
                total: $form.discCount
            )
            LabeledContent(L10n.text("metadataEditor.field.compilation")) {
                Toggle("", isOn: $form.isCompilation)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var playbackSection: some View {
        metadataSection("metadataEditor.section.playback") {
            LabeledContent(L10n.text("metadataEditor.field.rating")) {
                Stepper(
                    L10n.format("metadataEditor.rating.value", form.rating),
                    value: $form.rating,
                    in: 0...5
                )
                .monospacedDigit()
            }
            metadataField("metadataEditor.field.playCount", text: $form.playCount)
            LabeledContent(L10n.text("metadataEditor.field.comments")) {
                TextEditor(text: $form.comments)
                    .font(.body)
                    .frame(minHeight: 72)
                    .padding(4)
                    .background(AppTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AppTheme.rule.opacity(0.7))
                    }
            }
        }
    }

    private func metadataSection<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text(titleKey)).font(.headline)
            VStack(spacing: AppTheme.spaceSM) { content() }
        }
    }

    private func metadataField(_ key: String, text: Binding<String>) -> some View {
        let label = L10n.text(key)
        return LabeledContent(label) {
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func numberPair(
        _ key: String,
        number: Binding<String>,
        total: Binding<String>
    ) -> some View {
        LabeledContent(L10n.text(key)) {
            HStack(spacing: AppTheme.spaceXS) {
                TextField("", text: number).frame(width: 70)
                Text(L10n.text("metadataEditor.number.of"))
                    .foregroundStyle(AppTheme.secondaryInk)
                TextField("", text: total).frame(width: 70)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var isTrack: Bool {
        if case .track = target { return true }
        return false
    }

    private var isArtist: Bool {
        if case .artist = target { return true }
        return false
    }

    private var titleKey: String {
        if isTrack { return "metadataEditor.track.title" }
        if isArtist { return "metadataEditor.artist.title" }
        return "metadataEditor.album.title"
    }

    private var descriptionKey: String {
        if isTrack { return "metadataEditor.track.description" }
        if isArtist { return "metadataEditor.artist.description" }
        return "metadataEditor.album.description"
    }

    private var canSave: Bool {
        !form.artist.trimmedForMetadata.isEmpty
            && (isArtist || !form.album.trimmedForMetadata.isEmpty)
            && (!isTrack || !form.title.trimmedForMetadata.isEmpty)
    }

    private var artworkEditor: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text(
                isArtist ? "metadataEditor.artist.photo.title" : "metadataEditor.artwork.title"
            ))
            .font(.headline)

            Group {
                if let selectedArtworkImage {
                    Image(nsImage: selectedArtworkImage).resizable().scaledToFill()
                } else {
                    ArtworkThumbnail(
                        tracks: targetTracks,
                        subject: sourceArtworkSubject,
                        shape: isArtist ? .circle : .roundedRectangle,
                        fallbackSymbol: isArtist ? "person.crop.circle.fill" : "photo",
                        fallbackLetter: String((isArtist ? form.artist : form.album).prefix(1))
                            .uppercased()
                    )
                }
            }
            .frame(width: 144, height: 144)
            .clipShape(isArtist
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(
                    cornerRadius: AppTheme.radiusMedium,
                    style: .continuous
                )))

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
        case .album(_, _, _, let tracks): return tracks
        case .artist(_, _, let trackIDs):
            let ids = Set(trackIDs)
            return library.tracks.filter { ids.contains($0.id) }
        }
    }

    private var sourceArtworkSubject: ArtworkSubject {
        switch target {
        case .track(let track): .album(name: track.album, artist: track.artist)
        case .album(_, let name, let artist, _): .album(name: name, artist: artist)
        case .artist(_, let name, _): .artist(name: name)
        }
    }

    private var destinationArtworkSubject: ArtworkSubject {
        isArtist
            ? .artist(name: form.artist.trimmedForMetadata)
            : .album(
                name: form.album.trimmedForMetadata,
                artist: form.artist.trimmedForMetadata
            )
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
            let artwork = selectedArtworkData.map(AudioArtworkChange.set) ?? .unchanged
            switch target {
            case .track(let track):
                try await library.updateTrackMetadata(
                    id: track.id,
                    metadata: form.values,
                    artwork: artwork
                )
            case .album(_, _, _, let tracks):
                try await library.updateAlbumMetadata(
                    trackIDs: tracks.map(\.id),
                    metadata: form.values,
                    artwork: artwork
                )
            case .artist(_, _, let trackIDs):
                try await library.updateArtistMetadata(
                    trackIDs: trackIDs,
                    artist: form.artist.trimmedForMetadata
                )
            }
            try await persistArtworkChange()
            library.noteArtworkChanged()
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
