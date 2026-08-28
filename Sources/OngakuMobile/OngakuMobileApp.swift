import SwiftUI

@main
struct OngakuMobileApp: App {
    @StateObject private var sync = MobileSyncController()

    var body: some Scene {
        WindowGroup {
            MobileContentView()
                .environmentObject(sync)
                .tint(.orange)
                .task {
                    await sync.loadLibrary()
                    sync.start()
                }
        }
    }
}

