import AVFoundation
import AudioToolbox
import Foundation
import OngakuAudioDSP
import Testing
@testable import OngakuDesktop

struct AudioRecordingSettingsTests {
    @Test @MainActor func settingsPersistUndoAndRemainLockedDuringCapture() throws {
        let name = "RecordingSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AudioRoutingStore(defaults: defaults)
        let original = store.document
        let recorder = try #require(original.nodes.first { $0.kind == .recorder })
        var settings = AudioRecordingSettings()
        settings.quality = .pcm24; settings.title = "録音 / 录音"; settings.artist = "Test"
        store.perform(.recording(recorder.id, settings))
        #expect(store.document.nodes.first { $0.id == recorder.id }?.recording == settings)
        #expect(AudioRoutingStore(defaults: defaults).document == store.document)
        #expect(try store.document.plan() == original.plan())
        store.undo(); #expect(store.document == original)
        store.redo(); let saved = store.document
        store.setLocked(true); settings.title = "Changed"
        store.perform(.recording(recorder.id,settings))
        #expect(store.document == saved && store.error != nil)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AudioRoutingDocument.self,from: data) == original)
    }
    @Test func filenamesAreSafeAndUniqueAndInvalidFieldsRejected() throws {
        var settings = AudioRecordingSettings()
        settings.fileName = "../録音:测试\\name\n"
        let directory = URL(fileURLWithPath: "/tmp")
        let a = settings.recordingURL(in: directory,source: "Test")
        let b = settings.recordingURL(in: directory,source: "Test")
        #expect(a.deletingLastPathComponent().path == directory.path && a != b)
        #expect(a.pathExtension == "wav")
        settings.title = String(repeating: "あ",count: 1000)
        #expect(throws: (any Error).self) { try settings.validate() }
        #expect(throws: (any Error).self) { try AudioRecordingSettings().resolveDirectory() }
    }
    @Test(arguments: [16,24,32], [44100.0,48000.0,96000.0,192000.0])
    func outputQualityRateAndUnicodeMetadata(bits: Int, rate: Double) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48000,channels: 2,interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 4800))
        buffer.frameLength = 4800
        let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for n in 0..<9600 { samples[n] = 0.25 * sin(Float(n/2) * 2 * .pi * 440 / 48000) }
        var settings = AudioRecordingSettings()
        settings.title = "録音テスト / 录音"; settings.artist = "演奏者"; settings.album = "测试专辑"
        settings.genre = "Electronic"; settings.comment = "日本語と中文"
        let writer = try OngakuCaptureWriter(url: url,format: format.streamDescription.pointee,bitDepth: UInt32(bits),sampleRate: rate,info: settings.infoData, id3: settings.id3Data)
        writer.appendFrames(buffer.frameLength,buffers: buffer.audioBufferList)
        #expect(writer.finish() == noErr)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == rate)
        #expect(file.fileFormat.streamDescription.pointee.mBitsPerChannel == bits)
        #expect(abs(Double(file.length) - rate / 10) <= 1)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: read)
        let peak = (0..<Int(read.frameLength)).map { abs(read.floatChannelData![0][$0]) }.max() ?? 0
        #expect(peak > 0.24 && peak < 0.27)
        let metadata = try await AVURLAsset(url: url).load(.commonMetadata)
        let allMetadata = try await AVURLAsset(url: url).load(.metadata)
        for (identifier,value) in [(AVMetadataIdentifier.id3MetadataContentType,settings.genre),(.id3MetadataComments,settings.comment)] {
            let item = try #require(AVMetadataItem.metadataItems(from: allMetadata,filteredByIdentifier: identifier).first)
            #expect(try await item.load(.stringValue) == value)
        }
        for (key,value) in [(AVMetadataKey.commonKeyTitle,settings.title),(.commonKeyArtist,settings.artist),(.commonKeyAlbumName,settings.album)] {
            let item = try #require(metadata.first { $0.commonKey == key })
            #expect(try await item.load(.stringValue) == value)
        }
    }
}
