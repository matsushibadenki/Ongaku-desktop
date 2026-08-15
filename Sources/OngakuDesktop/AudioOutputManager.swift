import CoreAudio
import Foundation

struct SampleRateRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double

    func contains(_ rate: Double, tolerance: Double = 1) -> Bool {
        rate >= minimum - tolerance && rate <= maximum + tolerance
    }
}

struct AudioOutputConfiguration: Equatable, Sendable {
    let sourceRate: Double
    let requestedRate: Double
    let actualRate: Double

    var isUpsampling: Bool { actualRate > sourceRate + 1 }
}

enum UpsamplingPolicy {
    static let maximumRate = 384_000.0

    private static let rates44Family = [352_800.0, 176_400.0, 88_200.0, 44_100.0]
    private static let rates48Family = [384_000.0, 192_000.0, 96_000.0, 48_000.0]

    static func selectRate(sourceRate: Double, supportedRanges: [SampleRateRange]) -> Double? {
        guard sourceRate > 0, !supportedRanges.isEmpty else { return nil }
        let preferredFamily = belongsTo44Family(sourceRate) ? rates44Family : rates48Family
        let allStandardRates = (rates48Family + rates44Family).sorted(by: >)

        if let preferred = preferredFamily.first(where: {
            $0 >= sourceRate - 1 && isSupported($0, by: supportedRanges)
        }) {
            return preferred
        }
        if let fallback = allStandardRates.first(where: {
            $0 >= sourceRate - 1 && isSupported($0, by: supportedRanges)
        }) {
            return fallback
        }

        let cappedMaximum = supportedRanges
            .compactMap { range -> Double? in
                guard range.minimum <= maximumRate else { return nil }
                return min(range.maximum, maximumRate)
            }
            .max()
        return cappedMaximum
    }

    private static func belongsTo44Family(_ rate: Double) -> Bool {
        let distance44 = distanceToIntegerMultiple(rate, base: 44_100)
        let distance48 = distanceToIntegerMultiple(rate, base: 48_000)
        return distance44 < distance48
    }

    private static func distanceToIntegerMultiple(_ rate: Double, base: Double) -> Double {
        let multiple = max(1, (rate / base).rounded())
        return abs(rate - base * multiple)
    }

    private static func isSupported(_ rate: Double, by ranges: [SampleRateRange]) -> Bool {
        ranges.contains { $0.contains(rate) }
    }
}

struct AudioOutputManager {
    func configureDefaultOutput(sourceRate: Double) -> AudioOutputConfiguration? {
        guard let deviceID = defaultOutputDevice(),
              let currentRate = nominalSampleRate(deviceID),
              let targetRate = UpsamplingPolicy.selectRate(
                sourceRate: sourceRate,
                supportedRanges: availableSampleRates(deviceID)
              ) else {
            return nil
        }

        if abs(currentRate - targetRate) > 1 {
            setNominalSampleRate(targetRate, deviceID: deviceID)
        }
        let actualRate = nominalSampleRate(deviceID) ?? currentRate
        return AudioOutputConfiguration(
            sourceRate: sourceRate,
            requestedRate: targetRate,
            actualRate: actualRate
        )
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private func availableSampleRates(_ deviceID: AudioDeviceID) -> [SampleRateRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioValueRange>.size else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = Array(
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: count
        )
        let status = ranges.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ranges.map { SampleRateRange(minimum: $0.mMinimum, maximum: $0.mMaximum) }
    }

    private func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    private func setNominalSampleRate(_ rate: Double, deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return
        }
        var requestedRate = rate
        AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &requestedRate
        )
    }
}
