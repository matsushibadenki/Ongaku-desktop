import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowPresentationController: ObservableObject {
    static let miniContentSize = NSSize(width: 420, height: 124)

    @Published private(set) var isMiniPlayer = false

    private weak var managedWindow: NSWindow?
    private var regularFrame: NSRect?
    private var regularMinSize: NSSize?
    private var regularMaxSize: NSSize?
    private var wasResizable = true
    private var zoomButtonWasEnabled = true

    func attach(to window: NSWindow) {
        managedWindow = window
        updateMiniaturizeButtonHelp(in: window)
        if isMiniPlayer {
            enforceMiniPlayerSize(in: window)
        }
    }

    func toggleMiniPlayer(in window: NSWindow) {
        managedWindow = window
        isMiniPlayer ? restoreRegularPlayer(in: window) : showMiniPlayer(in: window)
    }

    private func showMiniPlayer(in window: NSWindow) {
        regularFrame = window.frame
        regularMinSize = window.minSize
        regularMaxSize = window.maxSize
        wasResizable = window.styleMask.contains(.resizable)
        zoomButtonWasEnabled = window.standardWindowButton(.zoomButton)?.isEnabled ?? true
        isMiniPlayer = true
        updateMiniaturizeButtonHelp(in: window)

        // Apply the window contract immediately so controls and automation never
        // observe a mini-player state with the regular window constraints.
        enforceMiniPlayerSize(in: window)

        Task { @MainActor in
            await Task.yield()
            guard self.managedWindow === window, self.isMiniPlayer else { return }
            window.minSize = NSSize(width: 1, height: 1)
            window.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            self.enforceMiniPlayerSize(in: window)
        }
    }

    private func enforceMiniPlayerSize(in window: NSWindow) {
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.styleMask.remove(.resizable)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentMinSize = Self.miniContentSize
        window.contentMaxSize = Self.miniContentSize
        window.setContentSize(Self.miniContentSize)
        window.setFrameTopLeftPoint(topLeft)
        window.minSize = window.frame.size
        window.maxSize = window.frame.size
    }

    private func restoreRegularPlayer(in window: NSWindow) {
        isMiniPlayer = false
        updateMiniaturizeButtonHelp(in: window)

        Task { @MainActor in
            await Task.yield()
            guard self.managedWindow === window, !self.isMiniPlayer else { return }
            window.minSize = NSSize(width: 1, height: 1)
            window.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            if self.wasResizable { window.styleMask.insert(.resizable) }
            window.standardWindowButton(.zoomButton)?.isEnabled = self.zoomButtonWasEnabled
            if let minSize = self.regularMinSize { window.minSize = minSize }
            if let maxSize = self.regularMaxSize { window.maxSize = maxSize }
            if let frame = self.regularFrame {
                window.setFrame(frame, display: true, animate: true)
            }
        }
    }

    private func updateMiniaturizeButtonHelp(in window: NSWindow) {
        window.standardWindowButton(.miniaturizeButton)?.toolTip = L10n.text(
            isMiniPlayer ? "miniPlayer.restore" : "miniPlayer.show"
        )
    }
}

struct WindowMiniaturizeBridge: NSViewRepresentable {
    @ObservedObject var controller: WindowPresentationController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.connect(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.controller = controller
        if let window = nsView.window {
            context.coordinator.connect(to: window)
        }
    }

    static func dismantleNSView(_ nsView: WindowProbeView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject {
        var controller: WindowPresentationController
        private weak var window: NSWindow?
        private weak var button: NSButton?
        private var originalTarget: AnyObject?
        private var originalAction: Selector?

        init(controller: WindowPresentationController) {
            self.controller = controller
        }

        func connect(to window: NSWindow?) {
            guard let window else { return }
            if self.window === window, button?.target === self {
                controller.attach(to: window)
                return
            }
            disconnect()
            guard let button = window.standardWindowButton(.miniaturizeButton) else { return }
            self.window = window
            self.button = button
            originalTarget = button.target
            originalAction = button.action
            button.target = self
            button.action = #selector(toggleMiniPlayer)
            controller.attach(to: window)
        }

        func disconnect() {
            if let button, button.target === self {
                button.target = originalTarget
                button.action = originalAction
            }
            button = nil
            window = nil
            originalTarget = nil
            originalAction = nil
        }

        @objc private func toggleMiniPlayer() {
            guard let window else { return }
            controller.toggleMiniPlayer(in: window)
        }
    }
}

final class WindowProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
