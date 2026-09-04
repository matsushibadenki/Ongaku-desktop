import AppKit
import SwiftUI

struct MusicBrainzCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss

    let referenceTrack: Track
    let candidates: [MusicBrainzCandidate]
    let onUse: (MusicBrainzCandidate, CoverArtCandidate?, Data?) -> Void

    @State private var selectedID: MusicBrainzCandidate.ID?
    @State private var artworkCandidates: [CoverArtCandidate] = []
    @State private var selectedArtworkID: CoverArtCandidate.ID?
    @State private var isLoadingArtwork = false
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            header

            HStack(alignment: .top, spacing: AppTheme.spaceLG) {
                candidateList
                Divider()
                candidateDetails
            }
            .frame(minHeight: 500)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.warning)
            }

            HStack {
                Text(L10n.text("musicbrainz.results.confirmation"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await useSelectedCandidate() }
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.text("musicbrainz.useSelected"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCandidate == nil || isApplying)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: 980, height: 720)
        .background(AppTheme.canvas)
        .onAppear { selectedID = candidates.first?.id }
        .task(id: selectedID) { await loadArtwork() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
            Text(L10n.text("musicbrainz.results.title"))
                .font(.title2.bold())
            Text(L10n.text("musicbrainz.results.description"))
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(L10n.text("musicbrainz.reference")) {
                Text("\(referenceTrack.title) — \(referenceTrack.artist)")
                    .lineLimit(1)
            }
            .font(.caption)
        }
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.spaceSM) {
                ForEach(candidates) { candidate in
                    Button {
                        selectedID = candidate.id
                    } label: {
                        candidateRow(candidate)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(width: 430)
    }

    private func candidateRow(_ candidate: MusicBrainzCandidate) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.title)
                    .font(.headline)
                    .lineLimit(1)
                if let badgeKey = matchBadgeKey(candidate) {
                    Text(L10n.text(badgeKey))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            candidate.matchKind == .titleAlbumMatch
                                ? AppTheme.good : AppTheme.warning
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (candidate.matchKind == .titleAlbumMatch
                                ? AppTheme.good : AppTheme.warning).opacity(0.10),
                            in: Capsule()
                        )
                }
                Spacer()
                Text(candidate.confidence, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(confidenceColor(candidate.confidence))
            }
            Text(candidate.artist)
                .font(.callout)
                .lineLimit(1)
            HStack(spacing: AppTheme.spaceXS) {
                Text(candidate.album).lineLimit(1)
                if let releaseYear = candidate.releaseYear {
                    Text("· \(releaseYear)")
                }
                if let country = candidate.country {
                    Text("· \(country)")
                }
            }
            .font(.caption)
            .foregroundStyle(AppTheme.secondaryInk)
            if let difference = candidate.durationDifference {
                Text(L10n.format("musicbrainz.durationDifference", difference))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
            }
            if let hint = matchHint(candidate) {
                Label(hint, systemImage: "lightbulb.fill")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.spaceSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 1)
        .background(
            selectedID == candidate.id ? AppTheme.accent.opacity(0.16) : AppTheme.surface,
            in: RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                .stroke(
                    selectedID == candidate.id ? AppTheme.accent : AppTheme.rule.opacity(0.55),
                    lineWidth: selectedID == candidate.id ? 2 : 1
                )
        }
    }

    @ViewBuilder
    private var candidateDetails: some View {
        if let candidate = selectedCandidate {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
                    metadataDetails(candidate)
                    artworkSection
                }
                .padding(.horizontal, 1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, AppTheme.spaceSM)
        } else {
            ContentUnavailableView(
                L10n.text("musicbrainz.results.noSelection"),
                systemImage: "music.note.list"
            )
        }
    }

    private func metadataDetails(_ candidate: MusicBrainzCandidate) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("musicbrainz.metadata.title")).font(.headline)
            detail(L10n.text("metadataEditor.field.title"), candidate.title)
            detail(L10n.text("metadataEditor.field.artist"), candidate.artist)
            detail(L10n.text("metadataEditor.field.album"), candidate.album)
            detail(L10n.text("metadataEditor.field.albumArtist"), candidate.albumArtist)
            detail(L10n.text("musicbrainz.releaseDate"), candidate.releaseDate ?? "—")
            detail(L10n.text("musicbrainz.country"), candidate.country ?? "—")
            detail(L10n.text("musicbrainz.mediaFormat"), candidate.mediaFormat ?? "—")
            detail(L10n.text("musicbrainz.isrc"), candidate.isrc ?? "—")
            detail(L10n.text("musicbrainz.recordingID"), candidate.recordingID, monospaced: true)
            detail(L10n.text("musicbrainz.releaseID"), candidate.releaseID, monospaced: true)
        }
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("musicbrainz.artwork.title")).font(.headline)
            if isLoadingArtwork {
                HStack(spacing: AppTheme.spaceSM) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("musicbrainz.artwork.loading"))
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
            } else if artworkCandidates.isEmpty {
                Text(L10n.text("musicbrainz.artwork.none"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
            } else {
                Button {
                    selectedArtworkID = nil
                } label: {
                    Label(
                        L10n.text("musicbrainz.artwork.keepCurrent"),
                        systemImage: selectedArtworkID == nil ? "checkmark.circle.fill" : "circle"
                    )
                }
                .buttonStyle(.plain)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                    ForEach(artworkCandidates) { artwork in
                        Button {
                            selectedArtworkID = artwork.id
                        } label: {
                            artworkCell(artwork)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func artworkCell(_ artwork: CoverArtCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: artwork.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(AppTheme.secondaryInk)
                default:
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 105)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))
            Text(artwork.types.isEmpty ? L10n.text("musicbrainz.artwork.other") : artwork.types.joined(separator: ", "))
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(5)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.radiusMedium))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusMedium)
                .stroke(
                    selectedArtworkID == artwork.id ? AppTheme.accent : AppTheme.rule.opacity(0.55),
                    lineWidth: selectedArtworkID == artwork.id ? 2 : 1
                )
        }
    }

    private var selectedCandidate: MusicBrainzCandidate? {
        candidates.first { $0.id == selectedID }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.85 { return AppTheme.good }
        if confidence >= 0.65 { return AppTheme.warning }
        return AppTheme.secondaryInk
    }

    private func matchHint(_ candidate: MusicBrainzCandidate) -> String? {
        switch candidate.matchKind {
        case .titleHint:
            L10n.format("musicbrainz.hint.title", referenceTrack.title)
        case .albumHint:
            L10n.format("musicbrainz.hint.album", referenceTrack.album)
        case .isrc, .titleAlbumMatch, .metadata:
            nil
        }
    }

    private func matchBadgeKey(_ candidate: MusicBrainzCandidate) -> String? {
        switch candidate.matchKind {
        case .titleAlbumMatch: "musicbrainz.match.titleAlbum"
        case .titleHint: "musicbrainz.match.title"
        case .isrc, .metadata, .albumHint: nil
        }
    }

    @MainActor
    private func loadArtwork() async {
        artworkCandidates = []
        selectedArtworkID = nil
        errorMessage = nil
        guard let candidate = selectedCandidate else { return }
        isLoadingArtwork = true
        do {
            let artwork = try await MusicBrainzService.shared.coverArt(for: candidate.releaseID)
            guard !Task.isCancelled, selectedID == candidate.id else { return }
            artworkCandidates = artwork
            selectedArtworkID = artwork.first(where: \.isFront)?.id
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoadingArtwork = false
    }

    @MainActor
    private func useSelectedCandidate() async {
        guard let candidate = selectedCandidate else { return }
        isApplying = true
        errorMessage = nil
        do {
            let selectedArtwork = artworkCandidates.first(where: { $0.id == selectedArtworkID })
            let artworkData: Data?
            if let artwork = selectedArtwork {
                artworkData = try await MusicBrainzService.shared.downloadArtwork(artwork)
            } else {
                artworkData = nil
            }
            onUse(candidate, selectedArtwork, artworkData)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isApplying = false
        }
    }
}
