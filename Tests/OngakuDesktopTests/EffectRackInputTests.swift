import AppKit
import SwiftUI
import Testing

@testable import OngakuDesktop

@Suite("Effect rack input ownership", .serialized)
@MainActor
struct EffectRackInputTests {
    @Test("EQ sections preserve every parameter exactly once and keep band controls together")
    func equalizerSections() {
        let sections = EqualizerParameterSection.all
        #expect(sections.map(\.id) == ["FILTER", "LOW BAND", "LMF", "HMF", "HIGH BAND", "OUTPUT"])
        let keys = sections.flatMap(\.parameters).map(\.key)
        #expect(keys == RealtimeAudioEffectKind.equalizer.parameterDefinitions.map(\.key))
        #expect(Set(keys).count == 14)
        #expect(sections[2].parameters.map(\.key) == ["lmfGain", "lmfFreq", "lmfQ", "lmfFocus"])
        #expect(sections[3].parameters.map(\.key) == ["hmfGain", "hmfFreq", "hmfQ", "hmfFocus"])
    }

    @Test("Detaching clears scroll ownership without publishing into a destroying SwiftUI graph")
    func detachDoesNotPublish() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        _ = fixture.router.route(fixture.scroll(at: fixture.controlPoint, phase: .began))
        #expect(fixture.router.isScrolling)
        let count = PublicationCount()
        let subscription = fixture.router.objectWillChange.sink {
            MainActor.assumeIsolated { count.value += 1 }
        }
        fixture.router.detach()
        #expect(!fixture.router.isScrolling)
        #expect(!fixture.router.controlPressed)
        #expect(count.value == 0, "Teardown must not notify a SwiftUI graph while it is invalidating")
        fixture.router.detach()
        #expect(count.value == 0, "Repeated teardown must also be silent")
        fixture.router.attach(to: fixture.scrollView)
        _ = fixture.router.route(fixture.scroll(at: fixture.controlPoint, phase: .began))
        #expect(fixture.router.isScrolling)
        #expect(count.value == 1, "A reattached live graph still receives scrolling updates")
        fixture.router.detach()
        #expect(count.value == 1)
        subscription.cancel()
    }

    @Test("Two-finger scroll starts over GUI or blank space while controls remain locked")
    func touchRouting() throws {
        let f = Fixture()
        defer { f.close() }
        #expect(f.router.route(f.scroll(at: f.controlPoint, phase: .began)) == nil)
        #expect(f.scrollView.wheelCount == 1)
        #expect(f.router.isScrolling)
        #expect(f.router.route(f.mouse(.leftMouseDown, at: f.controlPoint)) == nil)
        #expect(f.router.route(f.mouse(.leftMouseDragged, at: f.blankPoint)) == nil)
        #expect(f.router.route(f.mouse(.leftMouseUp, at: f.blankPoint)) == nil)
        _ = f.router.route(f.scroll(at: f.blankPoint, phase: .changed))
        #expect(f.scrollView.wheelCount == 2)
        _ = f.router.route(f.scroll(at: f.blankPoint, phase: .began))
        _ = f.router.route(f.scroll(at: f.controlPoint, phase: .changed))
        #expect(f.scrollView.wheelCount == 4)
        #expect(f.router.isScrolling)
    }

    @Test("Wheel scroll over a control reaches the scroll view, never the control")
    func mouseWheel() {
        let f = Fixture()
        defer { f.close() }
        #expect(f.router.route(f.scroll(at: f.controlPoint, precise: false)) == nil)
        #expect(f.scrollView.wheelCount == 1)
        #expect(f.router.isScrolling)
    }

    @Test("Control click/drag blocks scrolling and focus-induced clip movement until release")
    func dragAndFocus() async throws {
        let f = Fixture()
        defer { f.close() }
        let down = f.mouse(.leftMouseDown, at: f.controlPoint)
        #expect(f.router.route(down) === down)
        #expect(f.router.controlPressed)
        let original = f.scrollView.contentView.bounds.origin
        f.scrollView.contentView.scroll(to: NSPoint(x: 0, y: original.y + 30))
        #expect(f.scrollView.contentView.bounds.origin == original)
        _ = f.router.route(f.scroll(at: f.blankPoint, phase: .began))
        _ = f.router.route(f.scroll(at: f.blankPoint, precise: false))
        #expect(f.scrollView.wheelCount == 0)
        let up = f.mouse(.leftMouseUp, at: f.blankPoint)
        #expect(f.router.route(up) === up)
        #expect(!f.router.controlPressed)
        try await Task.sleep(for: .milliseconds(30))
        f.scrollView.contentView.scroll(to: NSPoint(x: 0, y: original.y + 30))
        #expect(f.scrollView.contentView.bounds.origin.y == original.y + 30)
    }

    @Test("Finger-up and momentum keep controls frozen; a fresh gesture can start afterwards")
    func momentum() async throws {
        let f = Fixture()
        defer { f.close() }
        _ = f.router.route(f.scroll(at: f.blankPoint, phase: .began))
        try await Task.sleep(for: .milliseconds(230))
        #expect(f.router.isScrolling)  // fingers held stationary must not unlock GUI
        _ = f.router.route(f.scroll(at: f.controlPoint, phase: .ended))
        _ = f.router.route(f.scroll(at: f.controlPoint, momentum: .began))
        #expect(f.router.isScrolling)
        #expect(f.scrollView.wheelCount == 3)
        _ = f.router.route(f.scroll(at: f.controlPoint, momentum: .ended))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!f.router.isScrolling)
        _ = f.router.route(f.scroll(at: f.controlPoint, phase: .began))
        #expect(f.scrollView.wheelCount == 5)
    }

    @Test("Scrollbar remains available and locks GUI; unrelated windows are untouched")
    func scrollbarAndScope() {
        let f = Fixture()
        defer { f.close() }
        let scroller = f.scrollView.verticalScroller!
        let point = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
        let down = f.mouse(.leftMouseDown, at: point)
        #expect(f.router.route(down) === down)
        #expect(f.router.isScrolling)
        #expect(!f.router.controlPressed)
        let foreign = RackEvent(kind: .scrollWheel, point: f.controlPoint, window: nil)
        #expect(f.router.route(foreign) === foreign)
        f.router.detach()
        #expect(!f.router.isScrolling)
    }

    @Test("Two-finger scroll can start on a partially clipped control to reveal it")
    func clippedControl() {
        let f = Fixture()
        defer { f.close() }
        f.control.frame.origin.y = 225
        let visible = f.control.bounds.intersection(f.control.visibleRect)
        #expect(visible.height > 0 && visible.height < f.control.bounds.height)
        let point = f.control.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        _ = f.router.route(f.scroll(at: point, phase: .began))
        #expect(f.scrollView.wheelCount == 1)
        _ = f.router.route(f.scroll(at: f.blankPoint, phase: .began))
        #expect(f.scrollView.wheelCount == 2)
    }

    @Test("Momentum produced during a control drag cannot move the rack after mouse-up")
    func dragMomentum() async throws {
        let f = Fixture()
        defer { f.close() }
        _ = f.router.route(f.mouse(.leftMouseDown, at: f.controlPoint))
        _ = f.router.route(f.scroll(at: f.blankPoint, phase: .began))
        _ = f.router.route(f.mouse(.leftMouseUp, at: f.blankPoint))
        _ = f.router.route(f.scroll(at: f.blankPoint, momentum: .began))
        #expect(f.scrollView.wheelCount == 0)
        _ = f.router.route(f.scroll(at: f.blankPoint, momentum: .ended))
        try await Task.sleep(for: .milliseconds(30))
        _ = f.router.route(f.scroll(at: f.blankPoint, phase: .began))
        #expect(f.scrollView.wheelCount == 1)
    }

    @Test("Detaching the rack releases ownership and position protection")
    func detach() {
        let f = Fixture()
        defer { f.close() }
        _ = f.router.route(f.mouse(.leftMouseDown, at: f.controlPoint))
        #expect(f.router.controlPressed)
        f.router.detach()
        #expect(!f.router.controlPressed)
        let event = f.scroll(at: f.controlPoint, phase: .began)
        #expect(f.router.route(event) === event)
        f.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 60))
        #expect(f.scrollView.contentView.bounds.origin.y == 60)
    }

    @Test("Rendered knob click/drag changes value without any clip movement, including at the viewport edge")
    func renderedKnobDoesNotScroll() async throws {
        for clipped in [false, true] {
            let input = EffectRackInputRouter()
            let value = KnobValue()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: LiveKnobRack(value: value, input: input))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer {
                input.detach()
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let initialScroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
            initialScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            initialScroll.reflectScrolledClipView(initialScroll.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let surface = try #require(descendants(host).compactMap { $0 as? KnobInputView }.first)
            let scroll = try #require(surface.enclosingScrollView)
            let document = try #require(scroll.documentView)
            let rect = document.convert(surface.bounds, from: surface)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + (clipped ? 20 : -80)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(80))
            let initialOrigin = scroll.contentView.bounds.origin
            let changes = ClipChanges()
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { _ in MainActor.assumeIsolated { changes.origins.append(scroll.contentView.bounds.origin) } }
            defer { NotificationCenter.default.removeObserver(observer) }
            let visible = surface.bounds.intersection(surface.visibleRect)
            #expect(!visible.isEmpty)
            let localPoint = NSPoint(x: visible.midX + 8, y: visible.midY)
            let down = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: surface.convert(localPoint, to: nil), modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if !clipped { #expect(input.route(down) === down) }
            // The clipped case deliberately bypasses the local monitor: the native
            // input surface must acquire protection before focus on its own.
            // Dispatch through the real window, including hit testing and mouse tracking.
            window.sendEvent(down)
            #expect(window.firstResponder === surface)
            #expect(value.number != 0.5)
            // A focus reveal request while the pointer owns a clipped knob must
            // be refused before the clip moves, rather than corrected afterwards.
            if clipped {
                #expect(surface.bounds.intersection(surface.visibleRect).height < surface.bounds.height)
                #expect(!surface.scrollToVisible(surface.bounds))
            }
            let drag = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDragged,
                    location: surface.convert(NSPoint(x: 42, y: 12), to: nil), modifierFlags: [], timestamp: 2,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            let clickedValue = value.number
            window.sendEvent(drag)
            #expect(!surface.autoscroll(with: drag))
            #expect(value.number != clickedValue)
            try await Task.sleep(for: .milliseconds(100))
            let up = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: drag.locationInWindow, modifierFlags: [], timestamp: 3,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
            _ = input.route(up)
            window.sendEvent(up)
            try await Task.sleep(for: .milliseconds(150))
            if clipped { #expect(!surface.scrollToVisible(surface.bounds)) }
            #expect(scroll.contentView.bounds.origin == initialOrigin)
            #expect(changes.origins.allSatisfy { $0 == initialOrigin })
            // Double-click reset and keyboard adjustment remain functional.
            let double = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: down.locationInWindow, modifierFlags: [], timestamp: 4,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 2, pressure: 1))
            _ = input.route(double)
            surface.mouseDown(with: double)
            #expect(value.number == 0.5)
            _ = input.route(up)
            surface.mouseUp(with: up)
            let key = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 5, windowNumber: window.windowNumber, context: nil,
                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126))
            surface.keyDown(with: key)
            #expect(value.number == 0.51)
            // Avoid delivering synthetic NullEvent storage into NSScrollView: use
            // the real controller's scrolling state via the existing probe fixture.
            let probe = Fixture()
            defer { probe.close() }
            _ = probe.router.route(probe.scroll(at: probe.controlPoint, phase: .began))
            surface.input = probe.router
            surface.mouseDown(with: down)
            surface.mouseDragged(with: drag)
            surface.keyDown(with: key)
            #expect(value.number == 0.51)
        }
    }

    @Test("Production effects rack preserves scroll position across repeated parameter clicks")
    func productionRackClicks() async throws {
        _ = NSApplication.shared
        let keys = ["audio.effectSettings.v1", "audio.effectsBypassed", AppLanguageSettings.defaultsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        let player = PlaybackController()
        player.setEffectsBypassed(false)
        for kind in AudioEffectModuleRegistry.activeKinds { player.setEffectEnabled(true, for: kind) }
        defer { player.clearCurrentTrack() }
        for language in ["en", "ja", "zh-Hans"] {
            UserDefaults.standard.set(language, forKey: AppLanguageSettings.defaultsKey)
            for width in [420.0, 900.0] {
                for mode in [AudioEffectPageTab.basic, .pro] {
                    for kind in AudioEffectModuleRegistry.activeKinds {
                        player.resetEffect(kind)
                        player.setEffectEnabled(true, for: kind)
                    }
                    let tabs = RackTabState()
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: width, height: 430),
                        styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let host = NSHostingView(rootView: ProductionRackFixture(tabs: tabs, player: player))
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(100))
                    tabs.tab = mode
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                    let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
                    let doc = try #require(scroll.documentView)
                    let fractions = mode == .pro ? [0.0, 0.25, 0.55, 0.85] : [0.0, 0.85]
                    for fraction in fractions {
                        let travel = max(0, doc.frame.height - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: travel * fraction))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(for: .milliseconds(150))
                        for click in 0..<3 {
                            let surfaces = descendants(host).compactMap { $0 as? KnobInputView }
                            let surface = try #require(
                                surfaces.first {
                                    $0.isEnabled && $0.bounds.intersection($0.visibleRect).height >= 52
                                        && $0.bounds.intersection($0.visibleRect).width >= 52
                                })
                            let visible = surface.bounds.intersection(surface.visibleRect)
                            let point = surface.convert(
                                NSPoint(
                                    x: visible.midX + 10, y: visible.minY + visible.height * (0.2 + Double(click) * 0.3)
                                ), to: nil)
                            let original = scroll.contentView.bounds.origin
                            let oldHeight = doc.frame.height
                            let picker = try #require(
                                descendants(host).compactMap { $0 as? EffectRackInputRegionView }.first {
                                    !$0.isViewport && abs($0.bounds.width - 230) < 1
                                })
                            let pickerFrame = picker.convert(picker.bounds, to: doc)
                            let surfaceFrame = surface.convert(surface.bounds, to: doc)
                            let beforeSettings = player.effectSettings
                            let changes = ClipChanges()
                            let observer = NotificationCenter.default.addObserver(
                                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
                            ) { _ in
                                MainActor.assumeIsolated { changes.origins.append(scroll.contentView.bounds.origin) }
                            }
                            let down = try #require(
                                NSEvent.mouseEvent(
                                    with: .leftMouseDown, location: point,
                                    modifierFlags: [], timestamp: 10, windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 1, clickCount: 1, pressure: 1))
                            window.sendEvent(down)
                            try await Task.sleep(for: .milliseconds(80))
                            let up = try #require(
                                NSEvent.mouseEvent(
                                    with: .leftMouseUp, location: point,
                                    modifierFlags: [], timestamp: 11, windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0))
                            window.sendEvent(up)
                            try await Task.sleep(for: .milliseconds(150))
                            NotificationCenter.default.removeObserver(observer)
                            let valueChanged = player.effectSettings != beforeSettings
                            // The first chosen angle may equal the existing value; subsequent
                            // angles must change it so this cannot pass with inert controls.
                            if click > 0 {
                                #expect(
                                    valueChanged,
                                    "Knob click must update a value: \(language), \(width), \(mode), \(fraction), \(click)"
                                )
                            }
                            #expect(
                                doc.frame.height == oldHeight,
                                "Document height changed at width \(width), language \(language)")
                            #expect(picker.convert(picker.bounds, to: doc) == pickerFrame, "Mode picker moved/resized")
                            #expect(
                                surface.convert(surface.bounds, to: doc) == surfaceFrame, "Clicked knob moved/resized")
                            #expect(scroll.contentView.bounds.origin == original)
                            #expect(changes.origins.allSatisfy { $0 == original })
                        }
                        // Exercise the real SwiftUI module switch, including the toolbar's
                        // enabled-count update, rather than only mutating the model.
                        let toggles = descendants(host).compactMap { $0 as? EffectRackInputRegionView }.filter {
                            abs($0.bounds.width - 38) < 1
                        }
                        let toggle = try #require(
                            toggles.min {
                                abs($0.convert($0.bounds, to: doc).minY - scroll.contentView.bounds.minY)
                                    < abs($1.convert($1.bounds, to: doc).minY - scroll.contentView.bounds.minY)
                            })
                        if toggle.bounds.intersection(toggle.visibleRect).height < 22 {
                            let frame = toggle.convert(toggle.bounds, to: doc)
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, frame.minY - 30)))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        let picker = try #require(
                            descendants(host).compactMap { $0 as? EffectRackInputRegionView }.first {
                                !$0.isViewport && abs($0.bounds.width - 230) < 1
                            })
                        let pickerFrame = picker.convert(picker.bounds, to: doc)
                        let oldHeight = doc.frame.height
                        let origin = scroll.contentView.bounds.origin
                        let input = try #require(descendants(host).compactMap { $0 as? KnobInputView }.first?.input)
                        let point = toggle.convert(NSPoint(x: 19, y: 11), to: nil)
                        for _ in 0..<2 {
                            let enabledBefore = player.effectSettings.filter(\.isEnabled).count
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                let event = try #require(
                                    NSEvent.mouseEvent(
                                        with: type, location: point,
                                        modifierFlags: [], timestamp: 12, windowNumber: window.windowNumber,
                                        context: nil,
                                        eventNumber: 3, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                                if let routed = input.route(event) { window.sendEvent(routed) }
                            }
                            try await Task.sleep(for: .milliseconds(150))
                            #expect(player.effectSettings.filter(\.isEnabled).count != enabledBefore)
                            #expect(
                                picker.convert(picker.bounds, to: doc) == pickerFrame,
                                "Mode picker moved/resized on switch")
                            #expect(doc.frame.height == oldHeight)
                            #expect(scroll.contentView.bounds.origin == origin)
                        }
                        if fraction == 0 && language == "ja"
                            && ProcessInfo.processInfo.environment["ONGAKU_CAPTURE_RACK"] == "1"
                        {
                            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(
                                to:
                                    URL(
                                        fileURLWithPath:
                                            "/private/tmp/ongaku-rack-ja-\(mode.rawValue)-\(Int(width)).png"))
                        }
                    }
                    if language == "ja" && width == 900 && mode == .pro
                        && ProcessInfo.processInfo.environment["ONGAKU_CAPTURE_RACK"] == "1"
                    {
                        let palette = DesktopAppearancePalette.shared
                        let savedAppearance = palette.selection
                        defer { palette.selection = savedAppearance }
                        window.setContentSize(NSSize(width: 900, height: 1400))
                        scroll.contentView.scroll(to: .zero)
                        for appearance in [AppAppearance.light, .dark, .pink, .purple, .green, .beige] {
                            palette.selection = appearance
                            window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                            host.layoutSubtreeIfNeeded()
                            try await Task.sleep(for: .milliseconds(100))
                            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(
                                to:
                                    URL(fileURLWithPath: "/private/tmp/ongaku-eq-knobs-\(appearance.rawValue).png"))
                        }
                    }
                }
            }
        }
    }

    @Test("Effect mode survives leaving and returning; OFF remains authoritative")
    func retainedModeAcrossPageVisits() async throws {
        _ = NSApplication.shared
        let key = "audio.effectsBypassed"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let player = PlaybackController(); player.setEffectsBypassed(false)
        defer { player.clearCurrentTrack() }
        let originalSettings = player.effectSettings
        let tabs = RackTabState(); tabs.tab = .pro
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ProductionRackFixture(tabs: tabs, player: player))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settleView() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        try await settleView()
        #expect(tabs.tab == .pro && !player.effectsBypassed)
        for _ in 0..<3 {
            tabs.showRack = false; try await settleView()
            tabs.showRack = true; try await settleView()
            #expect(tabs.tab == .pro && !player.effectsBypassed)
            #expect(player.effectSettings == originalSettings)
        }
        tabs.tab = .off; try await settleView()
        #expect(player.effectsBypassed)
        tabs.showRack = false; try await settleView()
        tabs.showRack = true; try await settleView()
        #expect(tabs.tab == .off && player.effectsBypassed)
        tabs.tab = .pro; try await settleView()
        #expect(!player.effectsBypassed && player.effectSettings == originalSettings)
        tabs.showRack = false; try await settleView()
        tabs.showRack = true; try await settleView()
        #expect(tabs.tab == .pro && !player.effectsBypassed)
        // A legacy installation may have persisted bypass without a tab value.
        tabs.showRack = false; try await settleView()
        player.setEffectsBypassed(true); tabs.tab = .basic
        tabs.showRack = true; try await settleView()
        #expect(tabs.tab == .off && player.effectsBypassed)
        #expect(player.effectSettings == originalSettings)
    }

    @Test("SwiftUI region connects to the actual ancestor scroll view")
    func hostingBridge() async throws {
        let router = EffectRackInputRouter()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView:
                ScrollView {
                    VStack {
                        Text("Control").frame(width: 90, height: 60).effectRackControl()
                        Color.clear.frame(height: 900)
                    }.effectRackViewport(router)
                }.environmentObject(router))
        window.contentView = host
        window.orderFront(nil)
        defer {
            router.detach()
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(host).compactMap { $0 as? EffectRackInputRegionView }.filter { !$0.isViewport }
        let control = try #require(controls.first)
        let p = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let event = RackEvent(kind: .leftMouseDown, point: p, window: window)
        #expect(router.route(event) === event)
        #expect(router.controlPressed)
    }
}

@MainActor
private final class Fixture {
    let router = EffectRackInputRouter()
    let scrollView = WheelProbe(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
    let window: NSWindow
    let control = EffectRackInputRegionView(frame: NSRect(x: 30, y: 30, width: 84, height: 84))
    var controlPoint: NSPoint { control.convert(NSPoint(x: 42, y: 42), to: nil) }
    var blankPoint: NSPoint { scrollView.contentView.convert(NSPoint(x: 250, y: 100), to: nil) }
    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 380, height: 1200))
        scrollView.documentView = document
        document.addSubview(control)
        window.contentView = scrollView
        scrollView.tile()
        scrollView.contentView.scroll(to: .zero)
        router.attach(to: scrollView)
        router.register(control)
    }
    func close() {
        router.detach()
        window.close()
    }
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        RackEvent(kind: type, point: point, window: window)
    }
    func scroll(at point: NSPoint, precise: Bool = true, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [])
        -> NSEvent
    {
        let e = RackEvent(kind: .scrollWheel, point: point, window: window)
        e.precise = precise
        e.touchPhase = phase
        e.inertia = momentum
        return e
    }
}
private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
private final class WheelProbe: NSScrollView {
    var wheelCount = 0
    override func scrollWheel(with event: NSEvent) { wheelCount += 1 }
}
private final class RackEvent: NSEvent {
    let kind: NSEvent.EventType
    let point: NSPoint
    weak var targetWindow: NSWindow?
    var precise = false
    var touchPhase: NSEvent.Phase = []
    var inertia: NSEvent.Phase = []
    init(kind: NSEvent.EventType, point: NSPoint, window: NSWindow?) {
        self.kind = kind
        self.point = point
        self.targetWindow = window
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { kind }
    override var locationInWindow: NSPoint { point }
    override var window: NSWindow? { targetWindow }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { touchPhase }
    override var momentumPhase: NSEvent.Phase { inertia }
}

@MainActor private final class KnobValue: ObservableObject { @Published var number = 0.5 }
@MainActor private final class ClipChanges { var origins: [NSPoint] = [] }

@MainActor
private struct LiveKnobRack: View {
    @ObservedObject var value: KnobValue
    let input: EffectRackInputRouter
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 500)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 92))]) {
                    ForEach(0..<12) { index in
                        RotaryKnob(
                            value: $value.number, range: 0...1, defaultValue: 0.5,
                            label: "Volume \(index)", valueText: "\(Int(value.number * 100))%")
                    }
                }
                Color.clear.frame(height: 500)
            }.effectRackViewport(input)
        }.environmentObject(input)
    }
}

@MainActor private final class RackTabState: ObservableObject {
    @Published var tab = AudioEffectPageTab.basic
    @Published var showRack = true
}
@MainActor private struct ProductionRackFixture: View {
    @ObservedObject var tabs: RackTabState
    let player: PlaybackController
    var body: some View {
        if tabs.showRack { EffectsRackView(selectedTab: $tabs.tab).environmentObject(player) }
        else { Color.clear }
    }
}

@MainActor private final class PublicationCount { var value = 0 }
