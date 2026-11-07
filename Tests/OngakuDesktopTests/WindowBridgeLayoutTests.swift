import AppKit
import SwiftUI
import Testing
@testable import OngakuDesktop

@MainActor @Suite("Deferred window bridge layout", .serialized)
struct WindowBridgeLayoutTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 700, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private final class TrackingHost: NSHostingView<WindowMiniaturizeBridge> {
        var insideLayout = false
        override func layout() {
            insideLayout = true
            defer { insideLayout = false }
            super.layout()
        }
    }
    private final class TrackingWindow: NSWindow {
        var isHostingLayout: () -> Bool = { false }
        var styleWritesDuringHostingLayout = 0
        override var styleMask: NSWindow.StyleMask {
            get { super.styleMask }
            set {
                if isHostingLayout() { styleWritesDuringHostingLayout += 1 }
                super.styleMask = newValue
            }
        }
    }

    @Test("The real SwiftUI bridge never changes window style inside hosting layout")
    func hostingLayoutDoesNotReenterWindow() async {
        let controller = WindowPresentationController()
        let window = TrackingWindow(contentRect: NSRect(x: 80, y: 80, width: 700, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = TrackingHost(rootView: WindowMiniaturizeBridge(controller: controller))
        window.isHostingLayout = { [weak host] in host?.insideLayout == true }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await nextTurn(); await nextTurn()
        host.layoutSubtreeIfNeeded()
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.styleWritesDuringHostingLayout == 0)
    }

    @Test("Window insertion notifications are deferred and coalesced")
    func insertionIsDeferred() async throws {
        let window = window(); defer { window.close() }
        let probe = WindowProbeView()
        var observed: [ObjectIdentifier?] = []
        probe.onWindowChange = { observed.append($0.map(ObjectIdentifier.init)) }
        try #require(window.contentView).addSubview(probe)
        probe.scheduleWindowChange(); probe.scheduleWindowChange()
        #expect(observed.isEmpty, "SwiftUI may be in NSHostingView.layout during insertion")
        await nextTurn()
        #expect(observed == [ObjectIdentifier(window)])
        probe.onWindowChange = nil
    }

    @Test("A moved probe configures only its latest window and hooks its current button")
    func latestWindowWins() async throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let controller = WindowPresentationController()
        let coordinator = WindowMiniaturizeBridge.Coordinator(controller: controller)
        let probe = WindowProbeView()
        probe.onWindowChange = { [weak coordinator] in coordinator?.connect(to: $0) }
        try #require(first.contentView).addSubview(probe)
        probe.removeFromSuperview()
        try #require(second.contentView).addSubview(probe)
        #expect(first.styleMask.contains(.fullSizeContentView))
        #expect(second.styleMask.contains(.fullSizeContentView))
        await nextTurn(); await nextTurn()
        #expect(first.styleMask.contains(.fullSizeContentView), "A stale captured owner must never be styled")
        #expect(!second.styleMask.contains(.fullSizeContentView))
        let button = try #require(second.standardWindowButton(.miniaturizeButton))
        #expect(button.target === coordinator)
        controller.toggleMiniPlayer(in: second)
        #expect(controller.isMiniPlayer && second.contentMinSize == WindowPresentationController.miniContentSize)
        controller.toggleMiniPlayer(in: second)
        #expect(!controller.isMiniPlayer && second.styleMask.contains(.resizable))
        WindowMiniaturizeBridge.dismantleNSView(probe, coordinator: coordinator)
        probe.scheduleWindowChange()
        await nextTurn()
        #expect(button.target !== coordinator)
    }

    @Test("Dismantling before queued attachment prevents later window mutation")
    func teardownCancelsNotification() async throws {
        let window = window(); defer { window.close() }
        let coordinator = WindowMiniaturizeBridge.Coordinator(controller: WindowPresentationController())
        let probe = WindowProbeView()
        probe.onWindowChange = { [weak coordinator] in coordinator?.connect(to: $0) }
        try #require(window.contentView).addSubview(probe)
        WindowMiniaturizeBridge.dismantleNSView(probe, coordinator: coordinator)
        await nextTurn()
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.standardWindowButton(.miniaturizeButton)?.target !== coordinator)
    }
}
