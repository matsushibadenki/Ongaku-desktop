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
        // SwiftUI can update the bridge during a window drag. Reapplying the
        // style mask at that point rebuilds the title bar while it is tracking.
        guard managedWindow !== window else { return }
        managedWindow = window
        // Keep the three-column layout below the title bar and its toolbar.
        // A full-size transparent title bar makes SwiftUI place the first row
        // of every NavigationSplitView column underneath those controls.
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.isMovable = true
        window.isMovableByWindowBackground = true
        // The navigation and transport paint their own backgrounds. Leave the
        // spectrum regions clear for native behind-window backdrop sampling.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarSeparatorStyle = .none
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

        // Restore the window contract synchronously. A detached MainActor task can
        // be delayed behind unrelated tests or UI work, leaving the window in a
        // non-resizable mini-player state after `isMiniPlayer` is already false.
        window.minSize = NSSize(width: 1, height: 1)
        window.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if wasResizable { window.styleMask.insert(.resizable) }
        window.standardWindowButton(.zoomButton)?.isEnabled = zoomButtonWasEnabled
        if let minSize = regularMinSize { window.minSize = minSize }
        if let maxSize = regularMaxSize { window.maxSize = maxSize }
        if let frame = regularFrame {
            // Hidden windows (including unit-test windows) have no visible
            // transition to animate and should restore deterministically.
            window.setFrame(frame, display: true, animate: window.isVisible)
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
        private var titleBarMouseMonitor: Any?
        private var titleBarDrag: TitleBarDrag?

        init(controller: WindowPresentationController) {
            self.controller = controller
        }

        func connect(to window: NSWindow?) {
            guard let window else {
                disconnect()
                return
            }
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
            titleBarMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handleTitleBarMouse(event) == nil
                }
                return consumed ? nil : event
            }
        }

        func disconnect() {
            if let titleBarMouseMonitor { NSEvent.removeMonitor(titleBarMouseMonitor) }
            titleBarMouseMonitor = nil
            titleBarDrag = nil
            if let button, button.target === self {
                button.target = originalTarget
                button.action = originalAction
            }
            button = nil
            window = nil
            originalTarget = nil
            originalAction = nil
        }

        private func handleTitleBarMouse(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            switch event.type {
            case .leftMouseDown:
                titleBarDrag = nil
                guard event.clickCount == 1,
                      !event.modifierFlags.contains(.control),
                      TitleBarDrag.canStart(in: window, at: event.locationInWindow)
                else { return event }
                titleBarDrag = TitleBarDrag(
                    windowOrigin: window.frame.origin,
                    mouseOrigin: window.convertPoint(toScreen: event.locationInWindow)
                )
                // Track this region ourselves: the transparent SwiftUI window
                // receives title-bar events without starting AppKit's move loop.
                return nil
            case .leftMouseDragged:
                guard let titleBarDrag else { return event }
                window.setFrameOrigin(titleBarDrag.windowOrigin(
                    for: window.convertPoint(toScreen: event.locationInWindow)
                ))
                return nil
            case .leftMouseUp:
                guard titleBarDrag != nil else { return event }
                titleBarDrag = nil
                return nil
            default:
                return event
            }
        }

        @objc private func toggleMiniPlayer() {
            guard let window else { return }
            controller.toggleMiniPlayer(in: window)
        }
    }
}

struct TitleBarDrag {
    let windowOrigin: NSPoint
    let mouseOrigin: NSPoint

    func windowOrigin(for mouseLocation: NSPoint) -> NSPoint {
        NSPoint(
            x: windowOrigin.x + mouseLocation.x - mouseOrigin.x,
            y: windowOrigin.y + mouseLocation.y - mouseOrigin.y
        )
    }

    @MainActor
    static func canStart(in window: NSWindow, at point: NSPoint) -> Bool {
        guard window.isMovable, window.attachedSheet == nil,
              !window.styleMask.contains(.fullScreen),
              point.y >= window.contentLayoutRect.maxY,
              let frameView = window.contentView?.superview,
              frameView.bounds.contains(frameView.convert(point, from: nil)),
              let hitView = frameView.hitTest(frameView.convert(point, from: nil))
        else { return false }

        // Hosted toolbar controls and search fields must retain their events,
        // including disabled buttons and their surrounding hit regions.
        if window.toolbar?.items.contains(where: { item in
            guard let view = item.view else { return false }
            return view.convert(view.bounds, to: nil).contains(point)
        }) == true { return false }
        var current: NSView? = hitView
        while let view = current {
            guard !(view is NSControl), view.mouseDownCanMoveWindow else { return false }
            current = view.superview
        }
        return true
    }
}

final class WindowProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
