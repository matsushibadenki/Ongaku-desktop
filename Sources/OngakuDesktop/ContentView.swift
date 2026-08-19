import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var meterSettings: PlayerMeterSettings
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            if meterSettings.barPosition == .top {
                persistentPlayer
            }

            navigationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if meterSettings.barPosition == .bottom {
                persistentPlayer
            }
        }
        .background(AppTheme.canvas)
        .tint(AppTheme.accent)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await library.importDroppedItems(urls) }
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                dropImportOverlay
                    .allowsHitTesting(false)
                    .padding(32)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await library.importFiles(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestImport)) { _ in
            isImporting = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestVerification)) { _ in
            Task { await library.verifyLibrary() }
        }
        .onAppear {
            library.undoManager = undoManager
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isImporting = true
                } label: {
                    Label(L10n.text("command.import"), systemImage: "plus")
                }
                .help(L10n.text("toolbar.importHelp"))

                Button {
                    Task { await library.verifyLibrary() }
                } label: {
                    Label(L10n.text("command.verify"), systemImage: "checkmark.shield")
                }
                .help(L10n.text("toolbar.verifyHelp"))
                .disabled(library.tracks.isEmpty || library.activity == .verifying)
            }
        }
        .toolbarBackground(AppTheme.windowBar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    private var persistentPlayer: some View {
        PlayerBar()
            .fixedSize(horizontal: false, vertical: true)
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } content: {
            LibraryContent()
                .navigationSplitViewColumnWidth(min: 660, ideal: 760)
        } detail: {
            TrackInspector()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        }
    }

    private var dropImportOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))

            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                Text(L10n.text("dropImport.title"))
                    .font(.title3.weight(.semibold))
                Text(L10n.text("dropImport.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .frame(maxWidth: 520, maxHeight: 230)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("dropImport.title"))
        .accessibilityHint(L10n.text("dropImport.subtitle"))
    }
}

#Preview("Desktop") {
    ContentView()
        .environmentObject(LibraryStore())
        .environmentObject(PlaybackController())
        .environmentObject(PlayerMeterSettings())
        .frame(width: 1240, height: 780)
}
