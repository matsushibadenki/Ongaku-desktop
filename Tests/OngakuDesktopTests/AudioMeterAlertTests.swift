import AVFoundation
import AppKit
import Foundation
import SwiftUI
import OngakuAudioDSP
import Testing
@testable import OngakuDesktop

struct AudioMeterAlertTests {
    @Test func colorThresholdsIncludeTheirUpperBoundary() {
        let green = AudioRoutingMeterScale.greenUpper
        let yellow = AudioRoutingMeterScale.yellowUpper
        #expect(AudioRoutingMeterScale.band(for: 0) == 0)
        #expect(AudioRoutingMeterScale.band(for: green) == 0)
        #expect(AudioRoutingMeterScale.band(for: green.nextUp) == 1)
        #expect(AudioRoutingMeterScale.band(for: yellow) == 1)
        #expect(AudioRoutingMeterScale.band(for: yellow.nextUp) == 2)
        #expect(AudioRoutingMeterScale.band(for: 1.2) == 2)
    }

    @Test @MainActor func warningSurvivesSilenceAndStopUntilAcknowledgedOrNewSession() {
        let levels = ApplicationAudioLevels(), source = UUID(), output = UUID()
        levels.update(peaks: [source: 0, output: 0.5], duration: 1, clipped: [source])
        #expect(levels.clippedNodes == [source])
        levels.update(peaks: [:], duration: 2)
        #expect(levels.clippedNodes == [source])
        var drained: UUID?
        levels.clearPendingClipping = { drained = $0 }
        levels.clearClipping(source)
        #expect(drained == source && levels.clippedNodes.isEmpty)
        levels.update(peaks: [source: 1, output: 1.1], duration: 3)
        #expect(levels.clippedNodes == [output])
        levels.startSession()
        #expect(levels.clippedNodes.isEmpty && levels.peaks.isEmpty && levels.elapsedSeconds == 0)
    }

    @Test(arguments: [Float(1.25), -1.25])
    func nativeLatchRetainsSingleSampleOverloadAcrossQuietBlocksAndTracksBranches(sample: Float) throws {
        var doc = AudioRoutingDocument.recordingAndMonitoring
        doc.nodes[1].parameters = [0.5]
        let steps = try doc.plan().nativeSteps
        let route = try steps.withUnsafeBufferPointer { try OngakuAudioRoute(steps: $0.baseAddress!, count: UInt($0.count), sampleRate: 48000) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        input.frameLength = 64; output.frameLength = 64
        func render(_ peak: Float) {
            for i in 0..<128 { input.floatChannelData![0][i] = 0 }
            input.floatChannelData![0][1] = peak
            #expect(route.processFrames(64, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
        }
        render(sample)
        for _ in 0..<100 { render(0) }
        #expect(route.peak(atStep: 0) == 0)
        #expect(route.takeClipping(atStep: 0))
        #expect(!route.takeClipping(atStep: 0))
        for step in 1..<steps.count { #expect(!route.takeClipping(atStep: UInt(step))) }
        render(1); render(-1)
        #expect(!route.takeClipping(atStep: 0))
        render(sample)
        #expect(route.takeClipping(atStep: 0))
        // Both terminal branches independently retain their overload flags.
        render(sample * 2)
        for step in 0..<steps.count { #expect(route.takeClipping(atStep: UInt(step))) }
        #expect(!route.takeClipping(atStep: 99))
    }

    @Test @MainActor func renderMeterStatesForVisualReview() throws {
        let values: [Float] = [0, 0.4, AudioRoutingMeterScale.greenUpper, 0.6, AudioRoutingMeterScale.yellowUpper, 0.9, 1.2, 0]
        let ids = values.map { _ in UUID() }, levels = ApplicationAudioLevels()
        levels.update(peaks: Dictionary(uniqueKeysWithValues: zip(ids, values)), duration: 1, clipped: [ids.last!])
        let root = URL(fileURLWithPath: "/tmp/ongaku-meter-alert-review", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let content = VStack(alignment: .leading, spacing: 12) {
                ForEach(ids, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 8) {
                        AudioRoutingMeterView(levels: levels, id: id)
                    }.padding(16).background(scheme == .light ? Color.white : Color(white: 0.16))
                }
            }.padding(16).frame(width: 280).background(scheme == .light ? Color(white: 0.92) : Color(white: 0.08))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let cgImage = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: root.appendingPathComponent(scheme == .light ? "light.png" : "dark.png"))
        }
    }
}
