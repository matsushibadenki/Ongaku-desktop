import Testing
@testable import OngakuDesktop

@Suite("Automatic output sample rate")
struct UpsamplingPolicyTests {
    private let commonRates = [
        44_100.0, 48_000.0, 88_200.0, 96_000.0,
        176_400.0, 192_000.0, 352_800.0, 384_000.0
    ].map { SampleRateRange(minimum: $0, maximum: $0) }

    @Test("44.1 kHz sources stay in the 44.1 kHz family")
    func selects44Family() {
        #expect(UpsamplingPolicy.selectRate(sourceRate: 44_100, supportedRanges: commonRates) == 352_800)
        #expect(UpsamplingPolicy.selectRate(sourceRate: 88_200, supportedRanges: commonRates) == 352_800)
    }

    @Test("48 kHz sources rise to 384 kHz")
    func selects48Family() {
        #expect(UpsamplingPolicy.selectRate(sourceRate: 48_000, supportedRanges: commonRates) == 384_000)
        #expect(UpsamplingPolicy.selectRate(sourceRate: 192_000, supportedRanges: commonRates) == 384_000)
    }

    @Test("The policy never exceeds 384 kHz")
    func capsAt384() {
        let continuous = [SampleRateRange(minimum: 44_100, maximum: 768_000)]
        #expect(UpsamplingPolicy.selectRate(sourceRate: 48_000, supportedRanges: continuous) == 384_000)
    }

    @Test("A device with limited rates falls back safely")
    func limitedDevice() {
        let limited = [48_000.0, 96_000.0].map { SampleRateRange(minimum: $0, maximum: $0) }
        #expect(UpsamplingPolicy.selectRate(sourceRate: 44_100, supportedRanges: limited) == 96_000)
    }
}
