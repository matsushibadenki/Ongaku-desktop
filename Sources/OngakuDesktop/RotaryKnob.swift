/* Hallmark · pre-emit critique: P5 H4 E5 S5 R5 V4
 * component: rotary parameter knob · genre: atmospheric · macrostructure: Workbench control
 * theme: Midnight · interaction: circular drag, keyboard, accessibility
 * visual diameter: 52 pt · minimum hit target: 64 pt
 */
import SwiftUI
import AppKit
import Combine

struct RotaryKnob: View {
    @EnvironmentObject private var input: EffectRackInputRouter
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let label: String
    let valueText: String
    var step: Double = 0.01

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var isFocused = false

    private let diameter: CGFloat = 52
    private let tickCount = 25

    private var normalizedValue: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private var rotation: Angle {
        .degrees(-135 + (270 * normalizedValue))
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                ticks

                metalKnob
                    .shadow(color: .black.opacity(0.30), radius: 2, y: 2)
                    .scaleEffect(isDragging ? 0.97 : (isHovering ? 1.025 : 1))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Rectangle())
            .overlay {
                KnobInputSurface(
                    isEnabled: isEnabled,
                    input: input,
                    onPosition: updatePosition,
                    onReset: { setValue(defaultValue) },
                    onStep: { adjust(by: $0 * step) },
                    onTracking: { isDragging = $0 },
                    onFocus: { isFocused = $0 }
                )
            }
            .onHover { isHovering = $0 && !input.isScrolling }

            VStack(spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .help(label)

                Text(valueText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isEnabled ? AppTheme.playbackAccent : AppTheme.secondaryInk)
                    .contentTransition(.numericText())
            }
            .frame(minHeight: 26, alignment: .top)
        }
        .frame(width: 84)
        .effectRackControl()
        .onChange(of: input.isScrolling) { _, scrolling in
            if scrolling { isHovering = false }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isDragging = false }
        }
        .onDisappear {
            isHovering = false
            isDragging = false
        }
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityHint(L10n.text("effects.knobHint"))
        .accessibilityAdjustableAction { direction in
            adjust(by: direction == .increment ? step : -step)
        }
    }

    /// Synth's black grip, machined silver cap and ivory index, drawn at the
    /// existing size so appearance changes never alter input or rack geometry.
    private var metalKnob: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 40, height: 40)
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.045)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 36, height: 36)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for index in 0..<40 {
                    let angle = Double(index) * .pi / 20
                    var ridge = Path()
                    ridge.move(to: CGPoint(x: center.x + cos(angle) * 15.5, y: center.y + sin(angle) * 15.5))
                    ridge.addLine(to: CGPoint(x: center.x + cos(angle) * 17.5, y: center.y + sin(angle) * 17.5))
                    context.stroke(ridge, with: .color(.white.opacity(0.18)), lineWidth: 0.65)
                }
            }
            .frame(width: 38, height: 38)
            Circle()
                .fill(AngularGradient(colors: [Color(white: 0.88), Color(white: 0.44),
                    Color(white: 0.93), Color(white: 0.58), Color(white: 0.92),
                    Color(white: 0.43), Color(white: 0.88)], center: .center, angle: .degrees(-35)))
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.7)
                }
                .overlay {
                    Canvas { context, size in
                        for inset in stride(from: 2.0, through: 11.0, by: 1.5) {
                            context.stroke(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)),
                                           with: .color(.black.opacity(0.12)), lineWidth: 0.35)
                        }
                    }
                }
                .frame(width: 26, height: 26)
            Capsule()
                .fill(Color(red: 0.96, green: 0.95, blue: 0.88))
                .frame(width: 2, height: 7)
                .offset(y: -14)
                .rotationEffect(rotation)
            Circle()
                .strokeBorder(isFocused ? AppTheme.playbackAccent : Color.clear, lineWidth: 1)
                .frame(width: 41, height: 41)
        }
        .frame(width: 42, height: 42)
        .allowsHitTesting(false)
    }

    private var ticks: some View {
        ZStack {
            ForEach(0..<tickCount, id: \.self) { index in
                let fraction = Double(index) / Double(tickCount - 1)
                Capsule()
                    .fill(isEnabled && fraction <= normalizedValue ? AppTheme.playbackAccent : AppTheme.rule)
                    .frame(width: 1.25, height: index.isMultiple(of: 4) ? 5 : 3)
                    .offset(y: -23)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func updatePosition(_ point: NSPoint) {
        let center = diameter / 2
        let dx = point.x - center
        let dy = point.y - center
        let degrees = min(max(atan2(dx, -dy) * 180 / .pi, -135), 135)
        let fraction = (degrees + 135) / 270
        setValue(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
    }

    private func adjust(by amount: Double) {
        setValue(value + amount)
    }

    private func setValue(_ newValue: Double) {
        guard isEnabled, !input.isScrolling else { return }
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        let stepped = (clamped / step).rounded() * step
        value = min(max(stepped, range.lowerBound), range.upperBound)
    }
}


/// One owner for each gesture in a rack. This also covers focus/autoscroll changes,
/// which are not scrollWheel events and were missed by the old per-knob monitor.
@MainActor
final class EffectRackInputRouter: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var scrolling = false
    private(set) var isScrolling: Bool {
        get { scrolling }
        set {
            guard scrolling != newValue else { return }
            objectWillChange.send()
            scrolling = newValue
        }
    }
    private(set) var controlPressed = false
    private var rejectedClick = false
    private var scrollerPressed = false
    private var touchAllowed: Bool?
    private var expiry: DispatchWorkItem?
    private var monitor: Any?
    private var boundsObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var restoringBounds = false
    private var frozenOrigin: NSPoint?
    private weak var scrollView: NSScrollView?
    private let regions = NSHashTable<EffectRackInputRegionView>.weakObjects()

    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restorePosition() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: scrollView.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
    }

    // Native controls acquire ownership before first-responder/focus callbacks,
    // even if the window delivered the click without the local event monitor.
    func beginKnobInteraction(in view: NSView) -> Bool {
        guard !isScrolling, let scroll = view.enclosingScrollView else { return false }
        attach(to: scroll)
        if !controlPressed {
            controlPressed = true
            frozenOrigin = scroll.contentView.bounds.origin
        }
        return true
    }

    func endControlInteraction() {
        guard controlPressed else { return }
        controlPressed = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.controlPressed else { return }
            self.restorePosition()
            self.frozenOrigin = nil
        }
    }

    func register(_ region: EffectRackInputRegionView) { regions.add(region) }
    func unregister(_ region: EffectRackInputRegionView) { regions.remove(region) }

    func detach() {
        // SwiftUI calls this while GraphHost is invalidating. Clear native
        // ownership synchronously without notifying that destroying graph.
        reset(publish: false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        boundsObserver = nil
        resignObserver = nil
        scrollView = nil
    }

    private func reset(publish: Bool = true) {
        expiry?.cancel()
        expiry = nil
        controlPressed = false
        rejectedClick = false
        scrollerPressed = false
        touchAllowed = nil
        frozenOrigin = nil
        if publish { isScrolling = false }
        else { scrolling = false }
    }

    private func restorePosition() {
        guard !restoringBounds, let origin = frozenOrigin, let scrollView else { return }
        let clip = scrollView.contentView
        // A tab switch can shrink the document during a click. Keep the frozen
        // position within the new scrollable range instead of exposing empty space.
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard clip.bounds.origin != target else { return }
        restoringBounds = true
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        restoringBounds = false
    }

    private func settle(after delay: Double = 0.18) {
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.scrollerPressed else { return }
            self.touchAllowed = nil
            self.isScrolling = false
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateScrollLifetime(_ event: NSEvent) {
        expiry?.cancel()
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            settle(after: 0)
        } else if event.phase.contains(.ended) {
            // The momentum stream follows finger-up; keep the same owner between them.
            settle()
        } else if event.phase.isEmpty && event.momentumPhase.isEmpty {
            settle()
        }
    }

    // Internal for event-routing regression tests using real AppKit views/events.
    func route(_ event: NSEvent) -> NSEvent? {
        guard let scrollView, let window = scrollView.window else { return event }
        if event.type == .leftMouseUp {
            let rejected = rejectedClick
            rejectedClick = false
            let endedScroller = scrollerPressed
            scrollerPressed = false
            // Retain the offset through the mouse-up action/focus update.
            endControlInteraction()
            if endedScroller { settle() }
            return rejected ? nil : event
        }
        guard event.window === window else { return event }
        let point = scrollView.convert(event.locationInWindow, from: nil)
        let inside = scrollView.bounds.intersection(scrollView.visibleRect).contains(point)
        guard inside || controlPressed || scrollerPressed || rejectedClick else { return event }
        let overControl = regions.allObjects.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.window === window
                && $0.bounds.intersection($0.visibleRect).contains($0.convert(event.locationInWindow, from: nil))
        }
        let overScroller = [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap { $0 }.contains {
            !$0.isHidden && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
        }
        switch event.type {
        case .leftMouseDown:
            if overScroller {
                expiry?.cancel()
                scrollerPressed = true
                isScrolling = true
                return event
            }
            if overControl {
                if isScrolling {
                    rejectedClick = true
                    return nil
                }
                controlPressed = true
                frozenOrigin = scrollView.contentView.bounds.origin
            }
            return event
        case .leftMouseDragged:
            return rejectedClick ? nil : event
        case .keyDown:
            return isScrolling ? nil : event
        case .scrollWheel:
            let precise = event.hasPreciseScrollingDeltas || !event.phase.isEmpty || !event.momentumPhase.isEmpty
            if controlPressed || scrollerPressed {
                if precise {
                    touchAllowed = false
                    updateScrollLifetime(event)
                }
                return nil
            }
            if precise {
                // Two-finger swipes scroll even over controls. Preserve only the
                // blocked stream produced during a click-drag through its momentum.
                if event.phase.contains(.began) || touchAllowed == nil {
                    touchAllowed = true
                }
                updateScrollLifetime(event)
                if touchAllowed == false { return nil }
            } else {
                // Discrete mouse wheels scroll even when the pointer is over a GUI.
                touchAllowed = nil
                settle()
            }
            isScrolling = true
            // Deliver directly to the container; controls cannot change their values.
            scrollView.scrollWheel(with: event)
            return nil
        default:
            return event
        }
    }
}

private struct EffectRackInputRegion: NSViewRepresentable {
    let router: EffectRackInputRouter
    var isViewport = false

    func makeNSView(context: Context) -> EffectRackInputRegionView {
        let view = EffectRackInputRegionView()
        view.router = router
        view.isViewport = isViewport
        return view
    }

    func updateNSView(_ view: EffectRackInputRegionView, context: Context) {
        view.connect()
    }

    static func dismantleNSView(_ view: EffectRackInputRegionView, coordinator: ()) {
        if view.isViewport { view.router?.detach() }
        else { view.router?.unregister(view) }
    }
}

final class EffectRackInputRegionView: NSView {
    weak var router: EffectRackInputRouter?
    var isViewport = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if isViewport { router?.detach() } else { router?.unregister(self) }
        } else { connect() }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        connect()
    }
    override func layout() {
        super.layout()
        connect()
    }
    func connect() {
        guard window != nil else { return }
        if isViewport {
            if let scroll = enclosingScrollView { router?.attach(to: scroll) }
        } else { router?.register(self) }
    }
}

private struct EffectRackControlModifier: ViewModifier {
    @EnvironmentObject private var input: EffectRackInputRouter
    func body(content: Content) -> some View {
        content.background { EffectRackInputRegion(router: input) }
    }
}

extension View {
    func effectRackControl() -> some View { modifier(EffectRackControlModifier()) }
    func effectRackViewport(_ router: EffectRackInputRouter) -> some View {
        background { EffectRackInputRegion(router: router, isViewport: true) }
    }
}

/// Native mouse tracking avoids SwiftUI focus scrolling when clicking a knob.
/// The SwiftUI layer draws the control and supplies its accessibility actions.
private struct KnobInputSurface: NSViewRepresentable {
    let isEnabled: Bool
    let input: EffectRackInputRouter
    let onPosition: (NSPoint) -> Void
    let onReset: () -> Void
    let onStep: (Double) -> Void
    let onTracking: (Bool) -> Void
    let onFocus: (Bool) -> Void

    func makeNSView(context: Context) -> KnobInputView { KnobInputView() }

    func updateNSView(_ view: KnobInputView, context: Context) {
        view.isEnabled = isEnabled
        view.input = input
        view.onPosition = onPosition
        view.onReset = onReset
        view.onStep = onStep
        view.onTracking = onTracking
        view.onFocus = onFocus
    }
}

final class KnobInputView: NSView {
    var isEnabled = true
    weak var input: EffectRackInputRouter?
    var onPosition: (NSPoint) -> Void = { _ in }
    var onReset: () -> Void = {}
    var onStep: (Double) -> Void = { _ in }
    var onTracking: (Bool) -> Void = { _ in }
    var onFocus: (Bool) -> Void = { _ in }
    private var tracking = false
    private var pointerFocused = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        pointerFocused = false
        finishTracking()
        onFocus(false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let input, input.beginKnobInteraction(in: self) else { return }
        // Mark pointer ownership BEFORE focus callbacks; late reveal requests
        // must also stay blocked after mouse-up until keyboard focus takes over.
        pointerFocused = true
        tracking = true
        window?.makeFirstResponder(self)
        onTracking(true)
        if event.clickCount == 2 { onReset() }
        else { onPosition(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking, isEnabled, input?.isScrolling != true else { return }
        onPosition(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { finishTracking() }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard !pointerFocused else { return false }
        return super.scrollToVisible(rect)
    }

    override func autoscroll(with event: NSEvent) -> Bool {
        guard !tracking else { return false }
        return super.autoscroll(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, input?.isScrolling != true else { return }
        pointerFocused = false
        switch event.keyCode {
        case 123, 125: onStep(-1)
        case 124, 126: onStep(1)
        default: super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishTracking() }
    }

    private func finishTracking() {
        guard tracking else { return }
        tracking = false
        input?.endControlInteraction()
        onTracking(false)
    }
}
