#import "AudioRoutingDSP.h"
#include <array>
#include <atomic>
#include <vector>
#include <cmath>
#include <algorithm>
#include <new>

BOOL OngakuValidateAudioRoute(const OngakuAudioRouteStep *steps, NSUInteger count) {
    if (!steps || count < 2 || count > 16 || steps[0].kind != 0) return NO;
    unsigned recorders = 0, devices = 0;
    for (NSUInteger i = 0; i < count; ++i) {
        auto s = steps[i];
        if (s.kind > 11 || !std::isfinite(s.p0) || !std::isfinite(s.p1) || !std::isfinite(s.p2)) return NO;
        if (i == 0) { if (s.inputA != -1 || s.inputB != -1 || s.bypassed || s.p0 < 1 || s.p0 > 10) return NO; continue; }
        if (s.kind == 0 || s.inputA < 0 || s.inputA >= i) return NO;
        if (s.kind == 6) ++recorders;
        if (s.kind == 7) ++devices;
        if ((steps[s.inputA].kind == 6 || steps[s.inputA].kind == 7)) return NO;
        if (s.kind == 4) { if (s.inputB < 0 || s.inputB >= i || (steps[s.inputB].kind == 6 || steps[s.inputB].kind == 7)) return NO; }
        else if (s.inputB != -1) return NO;
        if (s.kind >= 4 && s.kind < 9 && s.bypassed) return NO;
        if (s.kind == 9) {
            for (float gain : s.eqGains)
                if (!std::isfinite(gain) || gain < -12 || gain > 12) return NO;
        }
        switch (s.kind) {
            case 11:
                if (s.p0 < -24 || s.p0 > 0 || s.p1 < 10 || s.p1 > 1000) return NO;
                break;
            case 10:
                if (s.p0 < -60 || s.p0 > 0 || s.p1 < 1 || s.p1 > 20 || s.p2 < 1 || s.p2 > 100
                    || !std::isfinite(s.p3) || s.p3 < 10 || s.p3 > 1000
                    || !std::isfinite(s.p4) || s.p4 < 0 || s.p4 > 24) return NO;
                break;
            case 7: if (s.p0 < 0 || s.p0 > 1) return NO; break;
            case 1: if (s.p0 < 0 || s.p0 > 10) return NO; break;
            case 2: if (s.p0 < 20 || s.p0 > 20000) return NO; break;
            case 3: if (s.p0 < 1 || s.p0 > 2000 || s.p1 < 0 || s.p1 > .9f || s.p2 < 0 || s.p2 > 1) return NO; break;
            case 4: if (s.p0 < 0 || s.p0 > 1 || s.p1 < 0 || s.p1 > 1) return NO; break;
            default: break;
        }
    }
    // Every step must contribute to a recording/output sink (no unused plan).
    if (recorders > 1 || devices > 1 || recorders + devices == 0) return NO;
    std::array<bool,16> needed{};
    for (NSUInteger i = 0; i < count; ++i) if ((steps[i].kind == 6 || steps[i].kind == 7)) needed[i] = true;
    for (NSInteger i = count-1; i > 0; --i) if (needed[i]) {
        needed[steps[i].inputA] = true;
        if (steps[i].kind == 4) needed[steps[i].inputB] = true;
    }
    for (NSUInteger i = 0; i < count; ++i) if (!needed[i]) return NO;
    return YES;
}

struct RouteStereo { float l = 0, r = 0; };
// Native adaptation of Synth FXStereoLine: fixed storage, fractional read and
// circular write. Time changes are smoothed; pitch/reverse/sinc modes aren't ported.
struct RouteDelay {
    std::vector<RouteStereo> samples;
    size_t cursor = 0;
    float frames = 1;
    RouteStereo read() const {
        double position = double(cursor) - frames;
        if (position < 0) position += samples.size();
        auto index = size_t(position);
        const float fraction = float(position - index);
        const auto a = samples[index], b = samples[(index + 1) % samples.size()];
        return {a.l + (b.l-a.l)*fraction, a.r + (b.r-a.r)*fraction};
    }
    void write(RouteStereo value) { samples[cursor] = value; cursor = (cursor + 1) % samples.size(); }
};
// All payload fields are atomic: a concurrent snapshot never races plain data.
// A reader makes one bounded attempt per block and keeps its previous targets
// if publication is in progress. No spin, mutex, allocation or DSP reset in IO.
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
using RouteControls = std::array<float,54>; // Base controls plus ten sets of biquad coefficients
static RouteControls RouteControlValues(OngakuAudioRouteStep step, double rate) {
    float p0 = step.p0;
    if (step.kind == 2) p0 = float(1 - std::exp(-2 * M_PI * std::min(double(p0),rate*.45) / rate));
    if (step.kind == 3) p0 = float(rate * p0 / 1000);
    RouteControls controls{p0, step.p1, step.p2, step.bypassed ? 0.f : 1.f};
    if (step.kind == 11) {
        controls[0] = std::pow(10.f, step.p0 / 20.f);
        controls[1] = -std::expm1(-1000.0 / (rate * step.p1));
    }
    if (step.kind == 10) {
        controls[0] = std::pow(10.f, step.p0 / 20.f);
        controls[1] = 1.f / step.p1 - 1.f;
        controls[2] = -std::expm1(-1000.0 / (rate * step.p2));
        controls[4] = -std::expm1(-1000.0 / (rate * step.p3));
        controls[5] = std::pow(10.f, step.p4 / 20.f);
    }
    if (step.kind == 9) {
        constexpr double frequencies[] = {31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
        for (size_t band = 0; band < 10; ++band) {
            const auto offset = 4 + 5 * band;
            if (frequencies[band] >= rate / 2) {
                controls[offset] = 1;
                continue;
            }
            const double omega = 2 * M_PI * frequencies[band] / rate;
            const double alpha = std::sin(omega) / (2 * 1.41421356237);
            const double amplitude = std::pow(10.0, step.eqGains[band] / 40.0);
            const double a0 = 1 + alpha / amplitude;
            controls[offset] = (1 + alpha * amplitude) / a0;
            controls[offset+1] = -2 * std::cos(omega) / a0;
            controls[offset+2] = (1 - alpha * amplitude) / a0;
            controls[offset+3] = controls[offset+1];
            controls[offset+4] = (1 - alpha / amplitude) / a0;
        }
    }
    return controls;
}
// 128 chronological stereo min/max pairs. Only the audio thread writes.
struct RouteWaveform {
    static constexpr uint32_t capacity = 128;
    std::array<std::atomic<float>, capacity * 2> pairs{};
    std::atomic<uint32_t> cursor{0};
    uint32_t frames = 0;
    float low = 0, high = 0;

    void append(RouteStereo sample, uint32_t framesPerPair) {
        low = std::min({low, sample.l, sample.r});
        high = std::max({high, sample.l, sample.r});
        if (++frames < framesPerPair) return;
        const auto index = cursor.load(std::memory_order_relaxed);
        pairs[index * 2].store(low, std::memory_order_relaxed);
        pairs[index * 2 + 1].store(high, std::memory_order_relaxed);
        cursor.store((index + 1) % capacity, std::memory_order_release);
        frames = 0;
        low = high = 0;
    }

    void copy(float *output, NSUInteger count) const {
        const auto start = cursor.load(std::memory_order_acquire);
        for (NSUInteger i = 0; i < count; ++i) {
            const auto index = (start + capacity - count + i) % capacity;
            output[i * 2] = pairs[index * 2].load(std::memory_order_relaxed);
            output[i * 2 + 1] = pairs[index * 2 + 1].load(std::memory_order_relaxed);
        }
    }
};
@implementation OngakuAudioRoute {
    std::array<OngakuAudioRouteStep,16> _steps;
    std::array<RouteDelay,16> _delays;
    std::array<RouteStereo,16> _filters;
    std::array<std::array<std::atomic<float>,54>,16> _published;
    std::atomic<uint32_t> _generation;
    uint32_t _seenGeneration;
    std::array<RouteControls,16> _current, _goals;
    struct EQState { RouteStereo z1{}, z2{}; };
    std::array<std::array<EQState,10>,16> _eqState;
    std::array<float,16> _dynamicsGain;
    std::array<UInt32,16> _remaining;
    double _rate;
    UInt32 _rampFrames;
    std::array<std::atomic<float>,16> _peaks;
    std::array<std::atomic<uint32_t>,16> _clipped;
    NSUInteger _count;
    std::array<RouteWaveform,16> _waveforms;
    uint32_t _waveformFramesPerPair;
}
- (instancetype)initWithSteps:(const OngakuAudioRouteStep *)steps count:(NSUInteger)count sampleRate:(double)rate error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    if (!OngakuValidateAudioRoute(steps,count) || !std::isfinite(rate) || rate < 8000 || rate > 192000) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudio_ParamError userInfo:nil];
        return nil;
    }
    _generation.store(0); _seenGeneration = 0; _remaining.fill(0); _dynamicsGain.fill(1);
    _count = count; _rate = rate;
    _waveformFramesPerPair = std::max(1u, uint32_t(rate / 1000)); _rampFrames = UInt32(rate * 0.02);
    std::copy(steps,steps+count,_steps.begin());
    try {
        for (NSUInteger i = 0; i < count; ++i) {
            _peaks[i].store(0); _clipped[i].store(0);
            _current[i] = _goals[i] = RouteControlValues(steps[i],rate);
            for (size_t p=0;p<_current[i].size();++p) _published[i][p].store(_current[i][p]);
            if (steps[i].kind == 3) {
                _delays[i].samples.resize(size_t(rate*2)+4);
                _delays[i].frames = float(rate * steps[i].p0 / 1000);
            }
        }
    } catch (const std::bad_alloc &) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
        return nil;
    }
    return self;
}
- (BOOL)updateParameters:(const OngakuAudioRouteStep *)steps count:(NSUInteger)count error:(NSError **)error {
    bool valid = count == _count && OngakuValidateAudioRoute(steps,count);
    if (valid) for (NSUInteger i=0;i<count;++i) {
        if (steps[i].kind != _steps[i].kind || steps[i].inputA != _steps[i].inputA || steps[i].inputB != _steps[i].inputB) { valid = false; break; }
    }
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudio_ParamError userInfo:nil];
        return NO;
    }
    // seq_cst orders version and payload together; exactly one control producer.
    _generation.fetch_add(1);
    for (NSUInteger i=0;i<count;++i) {
        const auto values = RouteControlValues(steps[i],_rate);
        for (size_t p=0;p<_current[i].size();++p) _published[i][p].store(values[p]);
    }
    _generation.fetch_add(1);
    return YES;
}
- (OSStatus)processFrames:(UInt32)frames input:(const AudioBufferList *)input output:(AudioBufferList *)output {
    return [self processFrames:frames input:input recording:output monitor:nullptr];
}
- (OSStatus)processFrames:(UInt32)frames input:(const AudioBufferList *)input recording:(AudioBufferList *)recording monitor:(AudioBufferList *)monitor {
    if (!input || !frames || frames > 4096) return kAudio_ParamError;
    for (auto output : {recording, monitor}) if (output && (output->mNumberBuffers != 1
        || output->mBuffers[0].mNumberChannels != 2 || !output->mBuffers[0].mData
        || output->mBuffers[0].mDataByteSize < uint64_t(frames)*8)) return kAudio_ParamError;
    const bool planar = input->mNumberBuffers == 2;
    if (input->mNumberBuffers != 1 && !planar) return kAudio_ParamError;
    for (UInt32 b = 0; b < input->mNumberBuffers; ++b) {
        if (!input->mBuffers[b].mData || input->mBuffers[b].mNumberChannels != (planar ? 1 : 2)
            || input->mBuffers[b].mDataByteSize < uint64_t(frames)*(planar ? 4 : 8)) return kAudio_ParamError;
    }
    const auto *left = static_cast<const float *>(input->mBuffers[0].mData);
    const auto *right = planar ? static_cast<const float *>(input->mBuffers[1].mData) : left+1;
    const size_t stride = planar ? 1 : 2;

    const auto version = _generation.load();
    if (!(version & 1) && version != _seenGeneration) {
        std::array<RouteControls,16> snapshot{};
        for (NSUInteger i=0;i<_count;++i) for (size_t p=0;p<_current[i].size();++p) snapshot[i][p] = _published[i][p].load();
        if (_generation.load() == version) {
            for (NSUInteger i=0;i<_count;++i) if (snapshot[i] != _goals[i]) {
                _goals[i] = snapshot[i]; _remaining[i] = _rampFrames;
            }
            _seenGeneration = version;
        }
    }
    std::array<float,16> peaks{};
    for (UInt32 f = 0; f < frames; ++f) {
        RouteStereo values[16]{};
        for (NSUInteger i = 0; i < _count; ++i) {
            const auto s = _steps[i];
            auto &control = _current[i];
            if (_remaining[i]) {
                for (size_t p=0;p<(s.kind == 9 ? control.size() : (s.kind == 10 ? 6 : 4));++p) control[p] += (_goals[i][p]-control[p]) / _remaining[i];
                if (!--_remaining[i]) control = _goals[i];
            }
            // Source gain precedes every outgoing edge, including both sinks.
            // Keep float headroom; the source meter reports the amplified peak.
            if (i == 0) {
                values[0] = {left[f*stride]*control[0],right[f*stride]*control[0]};
                if (!std::isfinite(values[0].l) || !std::isfinite(values[0].r)) return kAudio_ParamError;
                peaks[0] = std::max(peaks[0],std::max(std::abs(values[0].l),std::abs(values[0].r)));
                continue;
            }
            const auto dry = values[s.inputA];
            auto a = dry;
            switch (s.kind) {
                // Only the terminal device sample is attenuated. Other branches
                // retain the unmodified upstream sample, including recording.
                case 11: {
                    const float peak = std::max(std::abs(a.l), std::abs(a.r));
                    const float ceiling = control[0];
                    const float target = peak > ceiling ? ceiling / peak : 1.f;
                    auto &gain = _dynamicsGain[i];
                    // Reduce immediately for each peak, then recover at the release rate.
                    gain = std::min(target, gain + (1.f - gain) * control[1]);
                    a = {std::clamp(a.l * gain, -ceiling, ceiling),
                         std::clamp(a.r * gain, -ceiling, ceiling)};
                    break;
                }
                case 10: {
                    const float peak = std::max(std::abs(a.l), std::abs(a.r));
                    const float target = peak > control[0] ? std::pow(peak / control[0], control[1]) : 1.f;
                    auto &gain = _dynamicsGain[i];
                    const float speed = target < gain ? control[2] : control[4];
                    gain += (target - gain) * speed;
                    const float outputGain = gain * control[5];
                    a = {a.l * outputGain, a.r * outputGain};
                    break;
                }
                case 9: {
                    for (size_t band = 0; band < 10; ++band) {
                        auto &state = _eqState[i][band];
                        const float *c = control.data() + 4 + 5 * band;
                        const RouteStereo result{c[0]*a.l + state.z1.l, c[0]*a.r + state.z1.r};
                        state.z1 = {c[1]*a.l - c[3]*result.l + state.z2.l,
                                    c[1]*a.r - c[3]*result.r + state.z2.r};
                        state.z2 = {c[2]*a.l - c[4]*result.l, c[2]*a.r - c[4]*result.r};
                        a = result;
                    }
                    break;
                }
                case 7:
                case 1: a.l *= control[0]; a.r *= control[0]; break;
                case 2: {
                    auto &state = _filters[i]; const auto c = control[0];
                    state.l += c*(a.l-state.l); state.r += c*(a.r-state.r);
                    a = state; break;
                }
                case 3: {
                    auto &line = _delays[i]; line.frames = control[0]; const auto wet = line.read();
                    line.write({a.l+wet.l*control[1],a.r+wet.r*control[1]});
                    a = {a.l*(1-control[2])+wet.l*control[2],a.r*(1-control[2])+wet.r*control[2]}; break;
                }
                case 4: {
                    const auto b = values[s.inputB];
                    a = {a.l*control[0]+b.l*control[1],a.r*control[0]+b.r*control[1]}; break;
                }
                default: break;
            }
            if ((s.kind >= 1 && s.kind <= 3) || s.kind >= 9) {
                a = {dry.l*(1-control[3])+a.l*control[3],dry.r*(1-control[3])+a.r*control[3]};
            }
            if (!std::isfinite(a.l) || !std::isfinite(a.r)) return kAudio_ParamError;
            if (s.kind == 8) _waveforms[i].append(a, _waveformFramesPerPair);
            values[i] = a;
            peaks[i] = std::max(peaks[i],std::max(std::abs(a.l),std::abs(a.r)));
        }
        for (NSUInteger i = 1; i < _count; ++i) {
            auto target = _steps[i].kind == 6 ? recording : _steps[i].kind == 7 ? monitor : nullptr;
            if (target) {
                auto *out = static_cast<float *>(target->mBuffers[0].mData);
                out[2*f] = values[i].l; out[2*f+1] = values[i].r;
            }
        }
    }
    for (NSUInteger i = 0; i < _count; ++i) {
        _peaks[i].store(peaks[i],std::memory_order_relaxed);
        if (peaks[i] > 1.f) _clipped[i].store(1,std::memory_order_relaxed);
    }
    return noErr;
}
- (void)copyWaveformAtStep:(NSUInteger)index into:(float *)pairs count:(NSUInteger)count {
    if (index < _count && _steps[index].kind == 8 && pairs && count <= RouteWaveform::capacity)
        _waveforms[index].copy(pairs, count);
}
- (float)peakAtStep:(NSUInteger)index { return index < _count ? _peaks[index].load(std::memory_order_relaxed) : 0; }
- (BOOL)takeClippingAtStep:(NSUInteger)index { return index < _count && _clipped[index].exchange(0,std::memory_order_relaxed) != 0; }
@end

@implementation OngakuMonitorBuffer {
    std::array<RouteStereo,32768> _ring;
    std::atomic<uint64_t> _read, _write, _rendered, _underruns;
    uint64_t _target;
    double _fraction;
    double _rateRatio;
    bool _primed;
}
- (instancetype)initWithSampleRate:(double)rate {
    return [self initWithSampleRate:rate renderRate:rate];
}
- (instancetype)initWithSampleRate:(double)rate renderRate:(double)renderRate {
    self = [super init];
    if (self) _rateRatio = rate / renderRate;
    if (self) _target = uint64_t(std::clamp(rate * 0.03, 256.0, 8192.0));
    return self;
}
- (BOOL)appendFrames:(UInt32)frames samples:(const float *)samples {
    if (!samples || frames > 4096) return NO;
    const auto write = _write.load(std::memory_order_relaxed);
    const auto read = _read.load(std::memory_order_acquire);
    if (write-read+frames > _ring.size()) return NO;
    for (UInt32 f = 0; f < frames; ++f) {
        if (!std::isfinite(samples[2*f]) || !std::isfinite(samples[2*f+1])) return NO;
        _ring[(write+f)%_ring.size()] = {samples[2*f],samples[2*f+1]};
    }
    _write.store(write+frames,std::memory_order_release);
    return YES;
}
- (void)renderFrames:(UInt32)frames samples:(float *)samples {
    if (!samples) return;
    std::fill(samples,samples+size_t(frames)*2,0);
    auto read = _read.load(std::memory_order_relaxed);
    const auto write = _write.load(std::memory_order_acquire);
    const auto needed = uint64_t(std::ceil(frames * _rateRatio));
    if (!_primed) {
        if (write-read < _target+needed) return;
        _primed = true;
    }
    // Corrections are capped at 0.2%, avoiding unbounded latency from clock drift.
    const double correction = std::clamp((double(write-read)-double(_target+needed))/double(_target)*0.001,-0.002,0.002);
    const double step = _rateRatio * (1 + correction);
    uint64_t delivered = 0;
    for (UInt32 f = 0; f < frames; ++f) {
        if (read+1 >= write) {
            _primed = false; _fraction = 0; _underruns.fetch_add(1,std::memory_order_relaxed); break;
        }
        const auto a = _ring[read%_ring.size()], b = _ring[(read+1)%_ring.size()];
        // Protect the hardware path against over-range processor chains. WAV
        // retains Float32 headroom. This is a sample clamp, not a true-peak limiter.
        samples[2*f] = std::clamp(float(a.l+(b.l-a.l)*_fraction),-1.f,1.f);
        samples[2*f+1] = std::clamp(float(a.r+(b.r-a.r)*_fraction),-1.f,1.f);
        _fraction += step;
        const auto advance = uint64_t(_fraction); read = std::min(read + advance, write); _fraction -= advance;
        ++delivered;
    }
    _read.store(read,std::memory_order_release);
    _rendered.fetch_add(delivered,std::memory_order_relaxed);
}
- (uint64_t)renderedFrames { return _rendered.load(std::memory_order_relaxed); }
- (uint64_t)underruns { return _underruns.load(std::memory_order_relaxed); }
@end
