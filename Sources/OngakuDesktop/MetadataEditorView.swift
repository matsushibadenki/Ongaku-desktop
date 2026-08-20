import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MetadataEditTarget: Identifiable {
    case track(Track)
    case tracks([Track])
    case album(id: UUID, name: String, artist: String, tracks: [Track])
    case artist(id: UUID, name: String, trackIDs: [Track.ID])

    var id: String {
        switch self {
        case .track(let track): "track:\(track.id.uuidString)"
        case .tracks(let tracks): "tracks:\(tracks.map(\.id.uuidString).sorted().joined(separator: ","))"
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

    init(tracks: [Track]) {
        self.init(track: tracks.first)
        guard !tracks.isEmpty else { return }
        title = Self.commonString(tracks, \.title)
        artist = Self.commonString(tracks, \.artist)
        artistSortName = Self.commonString(tracks, \.artistSortName)
        album = Self.commonString(tracks, \.album)
        albumSortName = Self.commonString(tracks, \.albumSortName)
        albumArtist = Self.commonString(tracks, \.albumArtist)
        albumArtistSortName = Self.commonString(tracks, \.albumArtistSortName)
        composer = Self.commonString(tracks, \.composer)
        composerSortName = Self.commonString(tracks, \.composerSortName)
        grouping = Self.commonString(tracks, \.grouping)
        genre = Self.commonString(tracks, \.genre)
        releaseYear = Self.commonOptionalInteger(tracks, \.releaseYear)
        trackNumber = Self.commonOptionalInteger(tracks, \.trackNumber)
        trackCount = Self.commonOptionalInteger(tracks, \.trackCount)
        discNumber = Self.commonOptionalInteger(tracks, \.discNumber)
        discCount = Self.commonOptionalInteger(tracks, \.discCount)
        isCompilation = Self.commonValue(tracks, \.isCompilation) ?? false
        rating = Self.commonValue(tracks, \.rating) ?? 0
        playCount = Self.commonValue(tracks, \.playCount).map(String.init) ?? ""
        comments = Self.commonString(tracks, \.comments)
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

    private static func commonValue<Value: Equatable>(
        _ tracks: [Track],
        _ keyPath: KeyPath<Track, Value>
    ) -> Value? {
        guard let first = tracks.first?[keyPath: keyPath],
              tracks.dropFirst().allSatisfy({ $0[keyPath: keyPath] == first }) else { return nil }
        return first
    }

    private static func commonString(
        _ tracks: [Track],
        _ keyPath: KeyPath<Track, String>
    ) -> String {
        commonValue(tracks, keyPath) ?? ""
    }

    private static func commonOptionalInteger(
        _ tracks: [Track],
        _ keyPath: KeyPath<Track, Int?>
    ) -> String {
        guard let common = commonValue(tracks, keyPath) else { return "" }
        return common.map(String.init) ?? ""
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
    @State private var selectedBulkFields: Set<TrackMetadataField> = []

    init(target: MetadataEditTarget) {
        self.target = target
        switch target {
        case .track(let track):
            _form = State(initialValue: MetadataFormState(track: track))
        case .tracks(let tracks):
            _form = State(initialValue: MetadataFormState(tracks: tracks))
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
                if !isBulk { artworkEditor }
                if isArtist {
                    metadataField("metadataEditor.field.artist", text: $form.artist)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
                            detailsSection
                            organizationSection
                            playbackSection
                            if isBulk { changePreviewSection }
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
                if isBulk {
                    Text(L10n.format("metadataEditor.bulk.songCount", targetTracks.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                } else if !isTrack {
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
            guard !isBulk else { return }
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
            if isTrack || isBulk {
                metadataField("metadataEditor.field.title", field: .title, text: $form.title)
            }
            metadataField("metadataEditor.field.artist", field: .artist, text: $form.artist)
            metadataField(
                "metadataEditor.field.artistSortName",
                field: .artistSortName,
                text: $form.artistSortName
            )
            metadataField("metadataEditor.field.album", field: .album, text: $form.album)
            metadataField(
                "metadataEditor.field.albumSortName",
                field: .albumSortName,
                text: $form.albumSortName
            )
            metadataField(
                "metadataEditor.field.albumArtist",
                field: .albumArtist,
                text: $form.albumArtist
            )
            metadataField(
                "metadataEditor.field.albumArtistSortName",
                field: .albumArtistSortName,
                text: $form.albumArtistSortName
            )
            metadataField(
                "metadataEditor.field.composer",
                field: .composer,
                text: $form.composer
            )
            metadataField(
                "metadataEditor.field.composerSortName",
                field: .composerSortName,
                text: $form.composerSortName
            )
        }
    }

    private var organizationSection: some View {
        metadataSection("metadataEditor.section.organization") {
            metadataField("metadataEditor.field.grouping", field: .grouping, text: $form.grouping)
            metadataField("metadataEditor.field.genre", field: .genre, text: $form.genre)
            metadataField(
                "metadataEditor.field.releaseYear",
                field: .releaseYear,
                text: $form.releaseYear
            )
            if isBulk {
                metadataField(
                    "metadataEditor.field.trackNumber",
                    field: .trackNumber,
                    text: $form.trackNumber
                )
                metadataField(
                    "metadataEditor.field.trackCount",
                    field: .trackCount,
                    text: $form.trackCount
                )
            } else if isTrack {
                numberPair(
                    "metadataEditor.field.trackNumber",
                    number: $form.trackNumber,
                    total: $form.trackCount
                )
            }
            if isBulk {
                metadataField(
                    "metadataEditor.field.discNumber",
                    field: .discNumber,
                    text: $form.discNumber
                )
                metadataField(
                    "metadataEditor.field.discCount",
                    field: .discCount,
                    text: $form.discCount
                )
                bulkLabeledContent("metadataEditor.field.compilation", field: .isCompilation) {
                    Toggle("", isOn: $form.isCompilation)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } else {
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
    }

    private var playbackSection: some View {
        metadataSection("metadataEditor.section.playback") {
            bulkLabeledContent("metadataEditor.field.rating", field: .rating) {
                Stepper(
                    L10n.format("metadataEditor.rating.value", form.rating),
                    value: $form.rating,
                    in: 0...5
                )
                .monospacedDigit()
            }
            metadataField(
                "metadataEditor.field.playCount",
                field: .playCount,
                text: $form.playCount
            )
            bulkLabeledContent("metadataEditor.field.comments", field: .comments) {
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

    private var changePreviewSection: some View {
        metadataSection("metadataEditor.bulk.preview.title") {
            if selectedBulkFields.isEmpty {
                Text(L10n.text("metadataEditor.bulk.preview.empty"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
            } else {
                ForEach(TrackMetadataField.allCases.filter(selectedBulkFields.contains), id: \.self) {
                    field in
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.spaceSM) {
                        Text(L10n.text(field.labelKey))
                            .foregroundStyle(AppTheme.secondaryInk)
                            .frame(width: 180, alignment: .leading)
                        Text(originalSummary(for: field))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(AppTheme.secondaryInk)
                        Text(newSummary(for: field))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
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

    private func metadataField(
        _ key: String,
        field: TrackMetadataField? = nil,
        text: Binding<String>
    ) -> some View {
        let label = L10n.text(key)
        return bulkLabeledContent(key, field: field) {
            TextField(label, text: text, prompt: mixedPrompt(for: field))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func bulkLabeledContent<Content: View>(
        _ key: String,
        field: TrackMetadataField?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isBulk, let field {
            LabeledContent {
                content().disabled(!selectedBulkFields.contains(field))
            } label: {
                Toggle(L10n.text(key), isOn: bulkFieldBinding(field))
                    .toggleStyle(.checkbox)
            }
        } else {
            LabeledContent(L10n.text(key)) { content() }
        }
    }

    private func bulkFieldBinding(_ field: TrackMetadataField) -> Binding<Bool> {
        Binding(
            get: { selectedBulkFields.contains(field) },
            set: { isSelected in
                if isSelected { selectedBulkFields.insert(field) }
                else { selectedBulkFields.remove(field) }
            }
        )
    }

    private func mixedPrompt(for field: TrackMetadataField?) -> Text? {
        guard isBulk, let field, isMixed(field) else { return nil }
        return Text(L10n.text("metadataEditor.bulk.mixed"))
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

    private var isBulk: Bool {
        if case .tracks = target { return true }
        return false
    }

    private var titleKey: String {
        if isBulk { return "metadataEditor.bulk.title" }
        if isTrack { return "metadataEditor.track.title" }
        if isArtist { return "metadataEditor.artist.title" }
        return "metadataEditor.album.title"
    }

    private var descriptionKey: String {
        if isBulk { return "metadataEditor.bulk.description" }
        if isTrack { return "metadataEditor.track.description" }
        if isArtist { return "metadataEditor.artist.description" }
        return "metadataEditor.album.description"
    }

    private var canSave: Bool {
        if isBulk {
            guard !selectedBulkFields.isEmpty else { return false }
            if selectedBulkFields.contains(.title), form.title.trimmedForMetadata.isEmpty {
                return false
            }
            if selectedBulkFields.contains(.artist), form.artist.trimmedForMetadata.isEmpty {
                return false
            }
            if selectedBulkFields.contains(.album), form.album.trimmedForMetadata.isEmpty {
                return false
            }
            return true
        }
        return !form.artist.trimmedForMetadata.isEmpty
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
        case .tracks(let tracks): return tracks
        case .album(_, _, _, let tracks): return tracks
        case .artist(_, _, let trackIDs):
            let ids = Set(trackIDs)
            return library.tracks.filter { ids.contains($0.id) }
        }
    }

    private var sourceArtworkSubject: ArtworkSubject {
        switch target {
        case .track(let track): .album(name: track.album, artist: track.artist)
        case .tracks(let tracks):
            .album(name: tracks.first?.album ?? "", artist: tracks.first?.artist ?? "")
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
            case .tracks(let tracks):
                try await library.updateTracksMetadata(
                    trackIDs: tracks.map(\.id),
                    patch: TrackMetadataPatch(fields: selectedBulkFields, values: form.values)
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
            if !isBulk {
                try await persistArtworkChange()
                library.noteArtworkChanged()
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


    private func isMixed(_ field: TrackMetadataField) -> Bool {
        Set(targetTracks.map { metadataSummary(for: field, track: $0) }).count > 1
    }

    private func originalSummary(for field: TrackMetadataField) -> String {
        let values = Set(targetTracks.map { metadataSummary(for: field, track: $0) })
        return values.count == 1 ? values.first ?? emptySummary : L10n.text("metadataEditor.bulk.mixed")
    }

    private func newSummary(for field: TrackMetadataField) -> String {
        metadataSummary(for: field, values: form.values)
    }

    private var emptySummary: String { L10n.text("metadataEditor.bulk.emptyValue") }

    private func metadataSummary(for field: TrackMetadataField, track: Track) -> String {
        metadataSummary(for: field, values: TrackMetadataValues(track: track))
    }

    private func metadataSummary(for field: TrackMetadataField, values: TrackMetadataValues) -> String {
        let value: String
        switch field {
        case .title: value = values.title
        case .artist: value = values.artist
        case .artistSortName: value = values.artistSortName
        case .album: value = values.album
        case .albumSortName: value = values.albumSortName
        case .albumArtist: value = values.albumArtist
        case .albumArtistSortName: value = values.albumArtistSortName
        case .composer: value = values.composer
        case .composerSortName: value = values.composerSortName
        case .grouping: value = values.grouping
        case .genre: value = values.genre
        case .releaseYear: value = values.releaseYear.map(String.init) ?? ""
        case .trackNumber: value = values.trackNumber.map(String.init) ?? ""
        case .trackCount: value = values.trackCount.map(String.init) ?? ""
        case .discNumber: value = values.discNumber.map(String.init) ?? ""
        case .discCount: value = values.discCount.map(String.init) ?? ""
        case .isCompilation:
            value = L10n.text(values.isCompilation ? "common.yes" : "common.no")
        case .rating: value = L10n.format("metadataEditor.rating.value", values.rating)
        case .playCount: value = String(values.playCount)
        case .comments: value = values.comments
        }
        return value.isEmpty ? emptySummary : value
    }
}

private extension TrackMetadataField {
    var labelKey: String {
        switch self {
        case .trackCount: "metadataEditor.field.trackCount"
        case .discCount: "metadataEditor.field.discCount"
        case .isCompilation: "metadataEditor.field.compilation"
        default: "metadataEditor.field.\(rawValue)"
        }
    }
}

private extension String {
    var trimmedForMetadata: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
