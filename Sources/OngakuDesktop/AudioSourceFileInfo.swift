import AVFoundation
import Foundation

/// Source metadata only: never reports the engine's Float32/96 kHz format as
/// the original file's encoding, and never exports/downloads a compatibility copy.
nonisolated struct AudioSourceFileInfo: Sendable {
    struct Row: Identifiable, Sendable {
        let id: String
        let value: String?
    }
    var container: String?
    var codec: String?
    var sampleRate: Double?
    var bitDepth: UInt32?
    var channels: UInt32?
    var bitRate: Float?
    var byteCount: Int64?
    var protectedAsset: Bool?
    var hasURL = false
    var readSucceeded = false
    var errorCode: String?

    var rows: [Row] {
        var rows = [
            Row(id: "sourceinfo.container", value: container),
            Row(id: "sourceinfo.codec", value: codec),
            Row(id: "sourceinfo.rate", value: sampleRate.map { String(format: "%g kHz", $0 / 1000) }),
            Row(id: "sourceinfo.depth", value: bitDepth.map { "\($0) bit" }),
            Row(id: "sourceinfo.channels", value: channels.map(String.init)),
            Row(id: "sourceinfo.bitrate", value: bitRate.map { String(format: "%.0f kbps", $0 / 1000) }),
            Row(id: "sourceinfo.size", value: byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
        ]
        if let errorCode { rows.append(Row(id: "sourceinfo.error", value: errorCode)) }
        return rows
    }

    static func read(url: URL?, protectedAsset: Bool? = nil) async -> Self {
        let work = Task.detached(priority: .utility) {
            var info = Self(protectedAsset: protectedAsset, hasURL: url != nil)
            guard let url else { return info }
            if url.isFileURL {
                let ext = url.pathExtension.uppercased()
                info.container = ext.isEmpty ? nil : ext
                info.byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            }
            do {
                try Task.checkCancellation()
                let asset = AVURLAsset(url: url)
                let protection = try await asset.load(.hasProtectedContent)
                info.protectedAsset = protectedAsset == true || protection
                guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                      let description = try await track.load(.formatDescriptions).first,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return info }
                let format = asbd.pointee
                info.codec = codecName(format.mFormatID)
                if format.mSampleRate.isFinite && format.mSampleRate > 0 { info.sampleRate = format.mSampleRate }
                if format.mChannelsPerFrame > 0 { info.channels = format.mChannelsPerFrame }
                // Compressed formats may report 0; Float32 decoding is not source bit depth.
                if format.mBitsPerChannel > 0 { info.bitDepth = format.mBitsPerChannel }
                if let rate = try? await track.load(.estimatedDataRate), rate.isFinite && rate > 0 {
                    info.bitRate = rate
                } else if format.mFormatID == kAudioFormatLinearPCM && format.mBytesPerFrame > 0,
                          let rate = info.sampleRate {
                    // Source PCM payload rate, excluding container overhead.
                    info.bitRate = Float(rate * Double(format.mBytesPerFrame) * 8)
                }
                try Task.checkCancellation()
                info.readSucceeded = true
            } catch is CancellationError { }
            catch {
                let error = error as NSError
                info.errorCode = "\(error.domain) (\(error.code))"
            }
            return info
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatFLAC: return "FLAC"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((id >> $0) & 255) }
            return bytes.allSatisfy { (32...126).contains($0) }
                ? String(bytes: bytes, encoding: .ascii)! : String(format: "0x%08X", id)
        }
    }
}
