import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @State private var isImporting = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .background(AppTheme.canvas)
        .tint(AppTheme.accent)
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
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isImporting = true
                } label: {
                    Label(L10n.text("command.import"), systemImage: "plus")
                }

                Button {
                    Task { await library.verifyLibrary() }
                } label: {
                    Label(L10n.text("command.verify"), systemImage: "checkmark.shield")
                }
                .disabled(library.tracks.isEmpty || library.activity == .verifying)
            }
        }
    }
}

#Preview("Desktop") {
    ContentView()
        .environmentObject(LibraryStore())
        .environmentObject(PlaybackController())
        .frame(width: 1240, height: 780)
}
