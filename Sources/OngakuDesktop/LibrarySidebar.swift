import SwiftUI

struct LibrarySidebar: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        List(selection: $library.selectedSection) {
            Section(L10n.text("sidebar.library")) {
                ForEach([LibrarySection.songs, .albums, .artists, .recentlyAdded]) { section in
                    Label(L10n.text(section.titleKey), systemImage: section.systemImage)
                        .fixedSize(horizontal: true, vertical: false)
                        .tag(section)
                }
            }

            Section(L10n.text("sidebar.processing")) {
                Label(
                    L10n.text(LibrarySection.effects.titleKey),
                    systemImage: LibrarySection.effects.systemImage
                )
                .fixedSize(horizontal: true, vertical: false)
                .tag(LibrarySection.effects)
            }

            Section(L10n.text("sidebar.integrity")) {
                Label {
                    HStack {
                        Text(L10n.text(LibrarySection.needsAttention.titleKey))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        if library.attentionCount > 0 {
                            Text("\(library.attentionCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.warning)
                        }
                    }
                } icon: {
                    Image(systemName: LibrarySection.needsAttention.systemImage)
                }
                .tag(LibrarySection.needsAttention)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.sidebar)
        .safeAreaInset(edge: .bottom) {
            librarySummary
        }
        .navigationTitle("Ongaku")
    }

    private var librarySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.format("sidebar.trackCount", library.tracks.count))
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)
            Text(ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.spaceMD)
        .padding(.vertical, AppTheme.spaceSM)
    }
}
