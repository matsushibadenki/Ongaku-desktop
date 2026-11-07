import AppKit
import QuartzCore
import Testing
@testable import OngakuDesktop

@MainActor @Suite("Spectrum backdrop layout", .serialized)
struct SpectrumGlassLayoutTests {
    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("Backdrop filters update after layout and coalesce to the latest bounds")
    func deferredResize() async throws {
        let view = SpectrumGlassView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        view.requestBackdropStyle(isDark: true, opacity: 0.7)
        view.layout()
        #expect(view.filteredSize == .zero, "Layer mutations must not happen inside layout")
        view.frame.size = NSSize(width: 480, height: 100)
        view.layout()
        view.frame.size = NSSize(width: 640, height: 120)
        view.requestBackdropStyle(isDark: false, opacity: 0.8)
        view.layout()
        await nextMainTurn()
        #expect(view.filteredSize == NSSize(width: 640, height: 120))
        #expect(view.appearance?.name == .aqua && view.alphaValue == 0.8)
        let mask = try #require(view.layer?.mask as? CAGradientLayer)
        #expect(mask.frame.size == view.bounds.size)
        #expect(view.layer?.backgroundFilters?.count == 2)
        view.layout()
        await nextMainTurn()
        #expect(view.layer?.mask === mask)
        view.requestBackdropStyle(isDark: true, opacity: 0.6)
        await nextMainTurn()
        #expect(view.appearance?.name == .darkAqua && view.alphaValue == 0.6)
        #expect(view.layer?.mask?.frame.size == view.bounds.size)
        #expect(view.hitTest(.zero) == nil && view.mouseDownCanMoveWindow)
    }

    @Test("Zero-size and retired views do not cause invalid filter work")
    func zeroAndRetirement() async {
        let view = SpectrumGlassView(frame: .zero)
        view.wantsLayer = true
        view.layout()
        await nextMainTurn()
        #expect(view.filteredSize == .zero)
        view.frame.size = NSSize(width: 160, height: 64)
        view.layout()
        await nextMainTurn()
        #expect(view.filteredSize == NSSize(width: 160, height: 64))
        weak var retired: SpectrumGlassView?
        do {
            let temporary = SpectrumGlassView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            retired = temporary
            temporary.layout()
        }
        await nextMainTurn()
        #expect(retired == nil, "Deferred updates must not retain a retired backdrop")
    }
}
