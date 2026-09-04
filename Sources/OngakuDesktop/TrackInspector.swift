import SwiftUI
import UniformTypeIdentifiers

struct TrackInspector: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @State private var lyricsEditorTrack: Track?
    @State private var relinkTrackID: Track.ID?
    @State private var isChoosingRelinkFile = false

    var body: some View {
        Group {
            if let track = library.selectedTrack {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
                        artwork(for: track)
                        identity(track)
                        lyricsPanel(track)
                        playbackDetails(track)
                        integrity(track)
                        fileDetails(track)

                        HStack {
                            Button {
                                player.play(track)
                            } label: {
                                Label(L10n.text("track.play"), systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button(L10n.text("track.reveal")) {
                                library.reveal(track)
                            }
                        }
                    }
                    .padding(AppTheme.spaceLG)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    L10n.text("inspector.empty.title"),
                    systemImage: "sidebar.right",
                    description: Text(L10n.text("inspector.empty.body"))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.sidebar)
        .navigationTitle(L10n.text("inspector.title"))
        .sheet(item: $lyricsEditorTrack) { track in
            LyricsEditorView(track: track)
                .environmentObject(library)
        }
        .fileImporter(
            isPresented: $isChoosingRelinkFile,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard let relinkTrackID, case .success(let urls) = result, let url = urls.first else {
                self.relinkTrackID = nil
                return
            }
            self.relinkTrackID = nil
            Task { await library.relinkTrack(id: relinkTrackID, to: url) }
        }
    }

    private func artwork(for track: Track) -> some View {
        ArtworkThumbnail(
            tracks: [track],
            subject: .album(name: track.album, artist: track.artist),
            shape: .roundedRectangle,
            fallbackSymbol: "waveform",
            fallbackLetter: String(track.album.prefix(1)).uppercased()
        )
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func identity(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
            Text(track.artist)
                .font(.body)
                .foregroundStyle(AppTheme.secondaryInk)
            Text(track.album)
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)
        }
    }

    private func lyricsPanel(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            HStack {
                Label(L10n.text("lyrics.title"), systemImage: "quote.bubble")
                    .font(.headline)
                Spacer()
                Button(L10n.text(track.lyrics == nil ? "lyrics.add" : "lyrics.edit")) {
                    lyricsEditorTrack = track
                }
                .buttonStyle(.borderless)
            }

            if let lyrics = track.lyrics {
                HStack(spacing: AppTheme.spaceXS) {
                    Text(L10n.text(lyrics.source.labelKey))
                    if lyrics.isSynced {
                        Label(L10n.text("lyrics.synced"), systemImage: "timer")
                    }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)

                if lyrics.isSynced {
                    syncedLyrics(lyrics.syncedLines, track: track)
                } else {
                    Text(lyrics.plainText)
                        .font(.callout)
                        .foregroundStyle(AppTheme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                    Text(L10n.text("lyrics.empty.title"))
                        .font(.callout.weight(.semibold))
                    Text(L10n.text("lyrics.empty.body"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AppTheme.spaceMD)
        .ongakuPanel()
    }

    private func syncedLyrics(_ lines: [TimedLyricsLine], track: Track) -> some View {
        let playbackTime = player.currentTrack?.id == track.id ? player.elapsed : 0
        let activeID = LyricsTimeline.activeLineID(in: lines, at: playbackTime)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.spaceSM) {
                    ForEach(lines) { line in
                        Button {
                            if player.currentTrack?.id != track.id { player.play(track) }
                            player.seek(to: line.time)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: AppTheme.spaceSM) {
                                Text(DurationFormatter.string(line.time))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppTheme.secondaryInk)
                                Text(line.text.isEmpty ? L10n.text("lyrics.instrumentalLine") : line.text)
                                    .font(.callout.weight(line.id == activeID ? .semibold : .regular))
                                    .foregroundStyle(line.id == activeID ? AppTheme.accent : AppTheme.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                    }
                }
                .padding(.horizontal, AppTheme.spaceXS)
                .padding(.vertical, AppTheme.spaceXS)
            }
            .frame(height: 240)
            .onChange(of: activeID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func integrity(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("inspector.integrity"))
                .font(.headline)
            HealthLabel(health: track.health, compact: false)
            detailRow(L10n.text("inspector.verified"), value: track.lastVerifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            VStack(alignment: .leading, spacing: 4) {
                Text("SHA-256")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                Text(track.sha256)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
        .padding(AppTheme.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ongakuPanel()
    }

    private func playbackDetails(_ track: Track) -> some View {
        let statistics = library.playbackStatistics(for: track.id)
        return VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("inspector.playback"))
                .font(.headline)

            HStack(spacing: AppTheme.spaceSM) {
                Button {
                    Task { await library.setPinned(!track.isPinned, for: track.id) }
                } label: {
                    Label(
                        L10n.text(track.isPinned ? "track.pin.remove" : "track.pin.add"),
                        systemImage: track.isPinned ? "pin.fill" : "pin"
                    )
                }

                Button {
                    Task { await library.setFavorite(!track.isFavorite, for: track.id) }
                } label: {
                    Label(
                        L10n.text(track.isFavorite ? "track.favorite.remove" : "track.favorite.add"),
                        systemImage: track.isFavorite ? "heart.fill" : "heart"
                    )
                }
            }
            .buttonStyle(.bordered)

            Menu {
                Button(L10n.text("track.rating.none")) {
                    Task { await library.setRating(0, for: track.id) }
                }
                Divider()
                ForEach(1...5, id: \.self) { rating in
                    Button(String(repeating: "★", count: rating)) {
                        Task { await library.setRating(rating, for: track.id) }
                    }
                }
            } label: {
                Label(ratingLabel(track.rating), systemImage: "star.fill")
            }
            .buttonStyle(.bordered)

            Toggle(
                L10n.text("track.playback.exclude"),
                isOn: Binding(
                    get: { track.isExcludedFromPlayback },
                    set: { isExcluded in
                        Task {
                            await library.setExcludedFromPlayback(isExcluded, for: track.id)
                        }
                    }
                )
            )

            Divider()
            detailRow(
                L10n.text("inspector.playCount"),
                value: statistics.playCount.formatted()
            )
            detailRow(
                L10n.text("inspector.skipCount"),
                value: statistics.skipCount.formatted()
            )
            detailRow(
                L10n.text("inspector.lastPlayed"),
                value: statistics.lastPlayedAt?.formatted(
                    date: .abbreviated,
                    time: .shortened
                ) ?? "—"
            )
        }
        .padding(AppTheme.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ongakuPanel()
    }

    private func ratingLabel(_ rating: Int) -> String {
        rating == 0
            ? L10n.text("track.rating.none")
            : String(repeating: "★", count: rating)
    }

    private func fileDetails(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("inspector.file"))
                .font(.headline)
            detailRow(L10n.text("inspector.size"), value: ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
            detailRow(L10n.text("inspector.duration"), value: DurationFormatter.string(track.duration))
            Text(track.managedPath)
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.secondaryInk)
                .textSelection(.enabled)
            if track.health != .verified {
                Divider()
                Text(L10n.text("relink.manualDescription"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    relinkTrackID = track.id
                    isChoosingRelinkFile = true
                } label: {
                    Label(L10n.text("relink.chooseFile"), systemImage: "link.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(AppTheme.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ongakuPanel()
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(AppTheme.secondaryInk)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(AppTheme.ink)
        }
        .font(.callout)
    }
}

private enum LyricsEditorMode: String, CaseIterable, Identifiable {
    case plain
    case synced

    var id: String { rawValue }
    var labelKey: String { "lyrics.editor.mode.\(rawValue)" }
}

private struct LyricsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let track: Track

    @State private var mode: LyricsEditorMode
    @State private var text: String
    @State private var importedTextSnapshot: String?
    @State private var onlineLyrics: TrackLyrics?
    @State private var onlineTextSnapshot: String?
    @State private var onlineCandidates: [LRCLIBCandidate] = []
    @State private var isShowingOnlineCandidates = false
    @State private var isSearchingOnline = false
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(track: Track) {
        self.track = track
        if let lyrics = track.lyrics, lyrics.isSynced {
            let serialized = LRCParser.serialize(lyrics.syncedLines)
            _mode = State(initialValue: .synced)
            _text = State(initialValue: serialized)
            _importedTextSnapshot = State(
                initialValue: lyrics.source == .lrcFile ? serialized : nil
            )
            _onlineLyrics = State(initialValue: lyrics.source == .lrclib ? lyrics : nil)
            _onlineTextSnapshot = State(
                initialValue: lyrics.source == .lrclib ? serialized : nil
            )
        } else {
            _mode = State(initialValue: .plain)
            let plainText = track.lyrics?.plainText ?? ""
            _text = State(initialValue: plainText)
            _importedTextSnapshot = State(initialValue: nil)
            _onlineLyrics = State(
                initialValue: track.lyrics?.source == .lrclib ? track.lyrics : nil
            )
            _onlineTextSnapshot = State(
                initialValue: track.lyrics?.source == .lrclib ? plainText : nil
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text("lyrics.editor.title"))
                    .font(.title2.bold())
                Text(L10n.format("lyrics.editor.song", track.title))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            Picker(L10n.text("lyrics.editor.format"), selection: $mode) {
                ForEach(LyricsEditorMode.allCases) { mode in
                    Text(L10n.text(mode.labelKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TextEditor(text: $text)
                .font(mode == .synced ? .body.monospaced() : .body)
                .padding(AppTheme.spaceXS)
                .scrollContentBackground(.hidden)
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.radiusSmall)
                        .strokeBorder(AppTheme.rule)
                }

            HStack(spacing: AppTheme.spaceSM) {
                if mode == .synced {
                    Label(syncValidationText, systemImage: syncValidationSymbol)
                        .font(.caption)
                        .foregroundStyle(syncValidationColor)
                } else {
                    Text(L10n.text("lyrics.editor.plainHint"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                Spacer()
                Button {
                    Task { await searchLRCLIB() }
                } label: {
                    if isSearchingOnline {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L10n.text("lrclib.search"), systemImage: "globe")
                    }
                }
                .disabled(isSearchingOnline)
                Button(L10n.text("lyrics.editor.importLRC")) { isImporting = true }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.warning)
            }

            HStack {
                Button(L10n.text("lyrics.editor.remove"), role: .destructive) {
                    text = ""
                    importedTextSnapshot = nil
                    onlineLyrics = nil
                    onlineTextSnapshot = nil
                }
                .disabled(text.isEmpty)
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
        .frame(width: 680, height: 620)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isSaving)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText],
            allowsMultipleSelection: false,
            onCompletion: importLRC
        )
        .sheet(isPresented: $isShowingOnlineCandidates) {
            LRCLIBCandidatePicker(
                track: track,
                candidates: onlineCandidates,
                onSelect: applyOnlineCandidate
            )
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedLyrics: TrackLyrics? {
        guard mode == .synced, !trimmedText.isEmpty else { return nil }
        if text == onlineTextSnapshot, let onlineLyrics, onlineLyrics.isSynced {
            return onlineLyrics
        }
        return try? LRCParser.parse(
            text,
            source: text == importedTextSnapshot ? .lrcFile : .manual
        )
    }

    private var canSave: Bool {
        if text == onlineTextSnapshot, onlineLyrics != nil { return true }
        return trimmedText.isEmpty || mode == .plain || parsedLyrics != nil
    }

    private var syncValidationText: String {
        guard !trimmedText.isEmpty else { return L10n.text("lyrics.editor.empty") }
        guard let parsedLyrics else { return L10n.text("lyrics.editor.invalidLRC") }
        return L10n.format("lyrics.editor.lineCount", parsedLyrics.syncedLines.count)
    }

    private var syncValidationSymbol: String {
        parsedLyrics == nil ? "exclamationmark.triangle" : "checkmark.circle.fill"
    }

    private var syncValidationColor: Color {
        parsedLyrics == nil ? AppTheme.warning : AppTheme.good
    }

    private func importLRC(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let contents = try String(contentsOf: url, encoding: .utf8)
            _ = try LRCParser.parse(contents)
            mode = .synced
            text = contents
            importedTextSnapshot = contents
            onlineLyrics = nil
            onlineTextSnapshot = nil
            errorMessage = nil
        } catch LRCParserError.noTimedLines {
            errorMessage = L10n.text("lyrics.editor.invalidLRC")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func searchLRCLIB() async {
        guard !isSearchingOnline else { return }
        isSearchingOnline = true
        errorMessage = nil
        do {
            onlineCandidates = try await LRCLIBService.shared.candidates(for: track)
            if onlineCandidates.isEmpty {
                errorMessage = L10n.text("lrclib.noResults")
            } else {
                isShowingOnlineCandidates = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearchingOnline = false
    }

    private func applyOnlineCandidate(_ candidate: LRCLIBCandidate) {
        guard let lyrics = candidate.record.trackLyrics() else { return }
        onlineLyrics = lyrics
        if lyrics.isSynced {
            mode = .synced
            text = LRCParser.serialize(lyrics.syncedLines)
        } else {
            mode = .plain
            text = lyrics.plainText
        }
        onlineTextSnapshot = text
        importedTextSnapshot = nil
        errorMessage = nil
        isShowingOnlineCandidates = false
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        do {
            let lyrics: TrackLyrics?
            if text == onlineTextSnapshot, let onlineLyrics {
                lyrics = onlineLyrics
            } else if trimmedText.isEmpty {
                lyrics = nil
            } else if mode == .plain {
                lyrics = TrackLyrics(
                    plainText: trimmedText,
                    source: .manual,
                    isManuallyEdited: true
                )
            } else {
                lyrics = parsedLyrics
            }
            try await library.updateTrackLyrics(id: track.id, lyrics: lyrics)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

private struct LRCLIBCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let track: Track
    let candidates: [LRCLIBCandidate]
    let onSelect: (LRCLIBCandidate) -> Void

    @State private var selectedID: LRCLIBCandidate.ID?

    init(
        track: Track,
        candidates: [LRCLIBCandidate],
        onSelect: @escaping (LRCLIBCandidate) -> Void
    ) {
        self.track = track
        self.candidates = candidates
        self.onSelect = onSelect
        _selectedID = State(initialValue: candidates.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text("lrclib.results.title"))
                    .font(.title2.bold())
                Text(L10n.text("lrclib.results.description"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppTheme.spaceMD) {
                referenceValue("lrclib.reference.title", value: track.title)
                referenceValue("lrclib.reference.artist", value: track.artist)
                referenceValue(
                    "lrclib.reference.duration",
                    value: DurationFormatter.string(track.duration)
                )
            }
            .padding(AppTheme.spaceMD)
            .ongakuPanel()

            ScrollView {
                LazyVStack(spacing: AppTheme.spaceSM) {
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
                .padding(.horizontal, AppTheme.spaceXS)
                .padding(.vertical, AppTheme.spaceXS)
            }

            HStack {
                Text(L10n.text("lrclib.results.confirmation"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("lrclib.useSelected")) {
                    guard let selected = selectedCandidate else { return }
                    onSelect(selected)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCandidate == nil)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: 780, height: 620)
        .background(AppTheme.canvas)
    }

    private var selectedCandidate: LRCLIBCandidate? {
        candidates.first { $0.id == selectedID }
    }

    private func referenceValue(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(key))
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
    }

    private func candidateRow(_ candidate: LRCLIBCandidate) -> some View {
        let isSelected = selectedID == candidate.id
        return Button {
            selectedID = candidate.id
        } label: {
            HStack(alignment: .top, spacing: AppTheme.spaceMD) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.secondaryInk)

                VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                    HStack(spacing: AppTheme.spaceXS) {
                        Text(candidate.record.trackName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                        if candidate.matchKind == .exact {
                            badge("lrclib.match.exact", color: AppTheme.good)
                        } else if candidate.matchKind == .titleAlbumMatch {
                            badge("lrclib.match.titleAlbum", color: AppTheme.good)
                        } else if candidate.matchKind == .titleHint {
                            badge("lrclib.match.titleHint", color: AppTheme.warning)
                        } else if candidate.matchKind == .albumHint {
                            badge("lrclib.match.albumHint", color: AppTheme.warning)
                        }
                        if candidate.record.syncedLyrics != nil {
                            badge("lrclib.format.synced", color: AppTheme.accent)
                        } else if candidate.record.instrumental {
                            badge("lrclib.format.instrumental", color: AppTheme.secondaryInk)
                        } else {
                            badge("lrclib.format.plain", color: AppTheme.secondaryInk)
                        }
                    }
                    Text(candidate.record.artistName)
                        .font(.callout)
                        .foregroundStyle(AppTheme.ink)
                    Text(candidate.record.albumName)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                        .lineLimit(1)
                    if let hint = matchHint(candidate) {
                        Label(hint, systemImage: "lightbulb.fill")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: AppTheme.spaceSM)

                VStack(alignment: .trailing, spacing: AppTheme.spaceXS) {
                    Text(candidate.confidence.formatted(
                        .percent.precision(.fractionLength(0))
                    ))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(confidenceColor(candidate.confidence))
                    Text(DurationFormatter.string(candidate.record.duration))
                        .font(.caption.monospacedDigit())
                    Text(durationDifferenceText(candidate.durationDifference))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                }
            }
            .padding(AppTheme.spaceMD)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 1)
            .background(isSelected ? AppTheme.accent.opacity(0.10) : AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.radiusMedium)
                    .strokeBorder(isSelected ? AppTheme.accent : AppTheme.rule)
            }
        }
        .buttonStyle(.plain)
    }

    private func badge(_ key: String, color: Color) -> some View {
        Text(L10n.text(key))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: Capsule())
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.9 { return AppTheme.good }
        if confidence >= 0.72 { return AppTheme.accent }
        return AppTheme.warning
    }

    private func durationDifferenceText(_ difference: TimeInterval) -> String {
        L10n.format("lrclib.durationDifference", difference)
    }

    private func matchHint(_ candidate: LRCLIBCandidate) -> String? {
        switch candidate.matchKind {
        case .titleHint:
            L10n.format("lrclib.hint.title", track.title)
        case .albumHint:
            L10n.format("lrclib.hint.album", track.album)
        case .exact, .titleAlbumMatch, .search:
            nil
        }
    }
}

private extension LyricsSource {
    var labelKey: String { "lyrics.source.\(rawValue)" }
}

struct HealthLabel: View {
    @Environment(\.controlActiveState) private var controlActiveState
    let health: FileHealth
    let compact: Bool
    var isSelected = false

    private var color: Color {
        switch health {
        case .verified: AppTheme.good
        case .unchecked: AppTheme.secondaryInk
        case .missing, .changed: AppTheme.warning
        case .unreadable: AppTheme.danger
        }
    }

    var body: some View {
        Group {
            if compact {
                Label(L10n.text(health.titleKey), systemImage: health.symbol)
                    .labelStyle(.iconOnly)
            } else {
                Label(L10n.text(health.titleKey), systemImage: health.symbol)
                    .labelStyle(.titleAndIcon)
            }
        }
        .foregroundStyle(
            isSelected && controlActiveState == .key ? Color.white : color
        )
        .accessibilityLabel(L10n.text(health.titleKey))
    }
}
