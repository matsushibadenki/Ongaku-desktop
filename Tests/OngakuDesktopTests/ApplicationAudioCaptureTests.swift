import AVFoundation
import Foundation
import Observation
import OngakuAudioDSP
import Testing
@testable import OngakuDesktop

struct ApplicationAudioCaptureTests {
    // Observation callbacks can run on a different executor; record safely.
    private final class ObservationCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    @Test @MainActor func meterUpdatesDoNotInvalidateClockAndUnchangedValuesDoNotNotify() {
        let levels = ApplicationAudioLevels(), id = UUID()
        levels.update(peaks: [id: 0.1], duration: 1.1)
        let clock = ObservationCount(), meter = ObservationCount()
        withObservationTracking { _ = levels.elapsedSeconds } onChange: { clock.increment() }
        withObservationTracking { _ = levels.peaks[id] } onChange: { meter.increment() }
        levels.update(peaks: [id: 0.1], duration: 1.2)
        #expect(clock.value == 0 && meter.value == 0)
        levels.update(peaks: [id: 0.5], duration: 1.9)
        #expect(clock.value == 0 && meter.value == 1)
        #expect(levels.elapsedSeconds == 1)
        levels.update(peaks: [id: 0.5], duration: 2.0)
        #expect(clock.value == 1 && levels.elapsedSeconds == 2)
    }
    @Test @MainActor func clockUpdatesDoNotInvalidateMeterAndSessionResetClearsLevels() {
        let levels = ApplicationAudioLevels(), id = UUID()
        levels.update(peaks: [id: 0.8], duration: 4.2)
        let meter = ObservationCount()
        withObservationTracking { _ = levels.peaks[id] } onChange: { meter.increment() }
        levels.update(peaks: [id: 0.8], duration: 5.3)
        #expect(meter.value == 0)
        levels.update(peaks: [:], duration: 0)
        #expect(meter.value == 1)
        #expect(levels.peaks.isEmpty && levels.elapsedSeconds == 0)
    }
    @Test(arguments: [false, true])
    func writesExactStereoPCMAndFinalizes(interleaved: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for item in list {
            let samples = item.mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<480 {
                for channel in 0..<Int(item.mNumberChannels) {
                    samples[frame * Int(item.mNumberChannels) + channel] = Float(frame % 17 - 8) / 32
                }
            }
        }
        let writer = try OngakuCaptureWriter(url: url, format: format.streamDescription.pointee)
        for _ in 0..<4 { writer.appendFrames(buffer.frameLength, buffers: buffer.audioBufferList) }
        #expect(writer.status == noErr)
        #expect(abs(writer.duration - 0.04) < 0.000001)
        #expect(writer.peak == 0.25)
        #expect(writer.finish() == noErr)
        #expect(writer.finish() == noErr)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 1920)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 2)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1920))
        try file.read(into: read)
        for channel in 0..<2 {
            for frame in 0..<1920 {
                #expect(read.floatChannelData![channel][frame] == Float((frame % 480) % 17 - 8) / 32)
            }
        }
    }

    @Test func existingRecordingIsNeverOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let original = Data("existing recording".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        #expect(throws: (any Error).self) { try OngakuCaptureWriter(url: url, format: format.streamDescription.pointee) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func unsupportedFormatCreatesNoFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true)!
        #expect(throws: (any Error).self) { try OngakuCaptureWriter(url: url, format: format.streamDescription.pointee) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func truncatedBufferFailsBeforeReadingPastEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        let writer = try OngakuCaptureWriter(url: url, format: format.streamDescription.pointee)
        writer.appendFrames(32, buffers: buffer.audioBufferList)
        #expect(writer.status != noErr)
        #expect(writer.duration == 0)
        #expect(writer.finish() != noErr)
        #expect(try AVAudioFile(forReading: url).length == 0)
    }

    @Test func nonfiniteSamplesFailWithoutWriting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = .nan
        let writer = try OngakuCaptureWriter(url: url, format: format.streamDescription.pointee)
        writer.appendFrames(1, buffers: buffer.audioBufferList)
        #expect(writer.finish() != noErr)
        #expect(try AVAudioFile(forReading: url).length == 0)
    }

    @Test func helperMatchingUsesBundleBoundary() {
        if #available(macOS 14.2, *) {
            #expect(ApplicationAudioSources.belongs("com.example.browser.helper", to: "com.example.browser"))
            #expect(ApplicationAudioSources.belongs("com.example.browser", to: "com.example.browser"))
            #expect(!ApplicationAudioSources.belongs("com.example.browserOther", to: "com.example.browser"))
        }
    }

    @Test func emptyProcessSelectionFailsWithoutCreatingFile() throws {
        if #available(macOS 14.2, *) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let engine = OngakuApplicationAudioCapture()
            #expect(throws: (any Error).self) { try engine.startProcesses([], url: url) }
            #expect(engine.stop() == noErr)
            #expect(engine.stop() == noErr)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}
