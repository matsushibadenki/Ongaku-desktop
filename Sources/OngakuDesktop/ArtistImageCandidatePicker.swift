import SwiftUI

struct ArtistImageCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss

    let artistName: String
    let candidates: [ArtistImageCandidate]
    let onUse: (ArtistImageCandidate, Data) -> Void

    @State private var selectedID: ArtistImageCandidate.ID?
    @State private var isDownloading = false
    @State private var errorMessage: String?

    init(
        artistName: String,
        candidates: [ArtistImageCandidate],
        onUse: @escaping (ArtistImageCandidate, Data) -> Void
    ) {
        self.artistName = artistName
        self.candidates = candidates
        self.onUse = onUse
        _selectedID = State(initialValue: candidates.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text("artistImage.results.title"))
                    .font(.title2.bold())
                Text(L10n.format("artistImage.results.description", artistName))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: AppTheme.spaceMD)],
                    spacing: AppTheme.spaceMD
                ) {
                    ForEach(candidates) { candidate in
                        candidateCard(candidate)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, AppTheme.spaceSM)
            }

            if let selectedCandidate {
                attributionPanel(selectedCandidate)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.warning)
            }

            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await useSelection() }
                } label: {
                    if isDownloading {
                        HStack(spacing: AppTheme.spaceXS) {
                            ProgressView().controlSize(.small)
                            Text(L10n.text("artistImage.downloading"))
                        }
                    } else {
                        Text(L10n.text("artistImage.useSelected"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCandidate == nil || isDownloading)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: 780, height: 680)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isDownloading)
    }

    private func candidateCard(_ candidate: ArtistImageCandidate) -> some View {
        let isSelected = selectedID == candidate.id
        return Button {
            selectedID = candidate.id
            errorMessage = nil
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
                AsyncImage(url: candidate.previewURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 154)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous))

                Text(candidate.artistName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: AppTheme.spaceXS) {
                    Text(L10n.text(candidate.source.titleKey))
                    Spacer()
                    Text(L10n.format("artistImage.match", Int((candidate.matchScore * 100).rounded())))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)
            }
            .padding(AppTheme.spaceSM)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.radiusLarge, style: .continuous))
            .background(
                isSelected ? AppTheme.accent.opacity(0.12) : AppTheme.surface,
                in: RoundedRectangle(cornerRadius: AppTheme.radiusLarge, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.radiusLarge, style: .continuous)
                    .strokeBorder(
                        isSelected ? AppTheme.accent : AppTheme.rule.opacity(0.65),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(candidate.artistName), \(L10n.text(candidate.source.titleKey))"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func attributionPanel(_ candidate: ArtistImageCandidate) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
            Text(L10n.text("artistImage.reference"))
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.spaceLG) {
                labeledValue(
                    "artistImage.attribution",
                    value: candidate.attribution ?? L10n.text("artistImage.notProvided")
                )
                labeledValue(
                    "artistImage.license",
                    value: candidate.licenseName ?? L10n.text("artistImage.providerTerms")
                )
                Spacer()
                if let sourceURL = candidate.sourceURL {
                    Link(destination: sourceURL) {
                        Label(L10n.text("artistImage.sourceLink"), systemImage: "arrow.up.right.square")
                    }
                }
                if let licenseURL = candidate.licenseURL {
                    Link(destination: licenseURL) {
                        Label(L10n.text("artistImage.licenseLink"), systemImage: "doc.text")
                    }
                }
            }
            .font(.caption)
        }
        .padding(AppTheme.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 1)
        .ongakuPanel()
    }

    private func labeledValue(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(key))
                .foregroundStyle(AppTheme.secondaryInk)
            Text(value).lineLimit(2)
        }
    }

    private var selectedCandidate: ArtistImageCandidate? {
        candidates.first { $0.id == selectedID }
    }

    @MainActor
    private func useSelection() async {
        guard let selectedCandidate else { return }
        isDownloading = true
        errorMessage = nil
        guard let data = await ArtworkResolver.shared.downloadArtistImage(selectedCandidate) else {
            errorMessage = L10n.text("artistImage.downloadFailed")
            isDownloading = false
            return
        }
        onUse(selectedCandidate, data)
        isDownloading = false
        dismiss()
    }
}
