#import "GainEnvelopeAudioUnit.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
static void check(bool ok, const char *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static float reference(float from, float to, uint64_t frame, uint64_t duration) {
    if (!duration || frame >= duration) return to;
    return float(from + (to - from) * (1 - cos(3.14159265358979323846 * double(frame) / duration)) * .5);
}
static float source(uint64_t position, unsigned ch) {
    return float(.12 * sin(double(position) * .137)) * (ch ? -.75f : 1.f);
}
int main() { @autoreleasepool {
    double maxResidual = 0;
    unsigned cases = 0;
    for (double rate : {44100., 48000., 96000., 192000.}) {
        for (unsigned channels : {1u, 2u}) {
            for (unsigned blockSize : {1u, 127u, 512u}) {
              for (double seconds : {.008, .016, .024}) {
                auto *node = [OngakuGainEnvelopeAudioUnit makeNode];
                auto *unit = (OngakuGainEnvelopeAudioUnit *)node.AUAudioUnit;
                check([unit rampToGain:1 durationFrames:20] == 0, "unallocated command accepted");
                auto *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
                NSError *error = nil;
                if (![unit.inputBusses[0] setFormat:format error:&error]) { fprintf(stderr,"rate=%.0f channels=%u block=%u duration=%.3f error=%s unit=%s max=%u capabilities=%s\n",rate,channels,blockSize,seconds,error.description.UTF8String,NSStringFromClass(unit.class).UTF8String,unit.inputBusses[0].maximumChannelCount,unit.channelCapabilities.description.UTF8String); check(false,"input format"); }
                check([unit.outputBusses[0] setFormat:format error:&error], "output format");
                unit.maximumFramesToRender = 512;
                check([unit allocateRenderResourcesAndReturnError:&error], "allocate");
                check(unit.latency == 0 && unit.tailTime == 0, "added latency/tail");
                const uint64_t duration = uint64_t(llround(rate * seconds));
                auto render = unit.internalRenderBlock;
                AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                    AUAudioFrameCount count, NSInteger bus, AudioBufferList *data) {
                    for (unsigned ch = 0; ch < channels; ++ch)
                        for (unsigned i = 0; i < count; ++i)
                            static_cast<float *>(data->mBuffers[ch].mData)[i] = source(uint64_t(time->mSampleTime) + i, ch);
                    return noErr;
                };
                auto block = [&](uint64_t start, unsigned count, float from, float to,
                                 uint64_t envelopeStart, uint64_t frames, bool silent = false) {
                    struct { UInt32 count; AudioBuffer buffers[2]; } raw = {channels, {{1,0,nullptr},{1,0,nullptr}}};
                    auto *data = reinterpret_cast<AudioBufferList *>(&raw);
                    AudioTimeStamp time = {}; time.mSampleTime = double(start); time.mFlags = kAudioTimeStampSampleTimeValid;
                    AudioUnitRenderActionFlags flags = 0;
                    AURenderPullInputBlock silentPull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *f, const AudioTimeStamp *, AUAudioFrameCount, NSInteger, AudioBufferList *) {
                        *f |= kAudioUnitRenderAction_OutputIsSilence; return noErr;
                    };
                    AURenderPullInputBlock input = silent ? silentPull : pull;
                    check(render(&flags, &time, count, 0, data, nullptr, input) == noErr, "render");
                    for (unsigned ch = 0; ch < channels; ++ch) for (unsigned i = 0; i < count; ++i) {
                        const float gain = reference(from, to, start + i - envelopeStart + 1, frames);
                        const float expected = silent || gain == 0 ? 0 : source(start+i, ch) * gain;
                        const float actual = static_cast<float *>(data->mBuffers[ch].mData)[i];
                        maxResidual = std::max(maxResidual, double(std::abs(actual - expected)));
                        check(std::abs(actual - expected) < 2e-7f, "sample-aligned cosine residual exceeded");
                        if (expected == 0) check(actual == 0, "endpoint is not exact silence");
                    }
                };
                if (rate == 48000 && channels == 2 && blockSize == 127) {
                    const auto failed = [unit rampToGain:1 durationFrames:1];
                    struct { UInt32 count; AudioBuffer buffers[2]; } raw = {2, {{1,0,nullptr},{1,0,nullptr}}};
                    auto *data = reinterpret_cast<AudioBufferList *>(&raw);
                    AudioTimeStamp time = {}; AudioUnitRenderActionFlags flags = 0;
                    AURenderPullInputBlock broken = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *, const AudioTimeStamp *, AUAudioFrameCount, NSInteger, AudioBufferList *) { return kAudioUnitErr_CannotDoInCurrentContext; };
                    check(render(&flags,&time,1,0,data,nullptr,nil) == kAudioUnitErr_NoConnection, "missing pull");
                    check(render(&flags,&time,513,0,data,nullptr,pull) == kAudioUnitErr_TooManyFramesToProcess, "oversized block");
                    check(render(&flags,&time,1,1,data,nullptr,pull) == kAudioUnitErr_InvalidElement, "wrong output bus");
                    check(render(&flags,&time,1,0,data,nullptr,broken) == kAudioUnitErr_CannotDoInCurrentContext, "upstream failure");
                    check(![unit isRampComplete:failed], "failed pull advanced completion");
                    block(10,1,0,1,10,1);
                    check([unit isRampComplete:failed], "valid pull did not advance");
                    [unit reset];
                }
                const auto token = [unit rampToGain:1 durationFrames:duration];
                check(token && ![unit isRampComplete:token], "completed before rendering");
                // No further control-thread writes: UI delay cannot bunch the envelope.
                uint64_t position = 0;
                while (position < duration - 1) {
                    unsigned count = unsigned(std::min(uint64_t(blockSize), duration - 1 - position));
                    block(position, count, 0, 1, 0, duration); position += count;
                }
                check(![unit isRampComplete:token], "completion rounded to block boundary");
                block(position, 1, 0, 1, 0, duration); ++position;
                check([unit isRampComplete:token], "rendered endpoint not acknowledged");
                const auto down = [unit rampToGain:0 durationFrames:duration];
                check(![unit isRampComplete:token], "old completed token owns new ramp");
                const uint64_t downStart = position, half = duration / 2;
                uint64_t rendered = 0;
                while (rendered < half) {
                    unsigned count = unsigned(std::min(uint64_t(blockSize), half - rendered));
                    block(position, count, 1, 0, downStart, duration); position += count; rendered += count;
                }
                const float current = reference(1, 0, half, duration);
                const auto up = [unit rampToGain:.8f durationFrames:duration];
                check(![unit isRampComplete:down], "superseded ramp acknowledged");
                const uint64_t upStart = position;
                for (uint64_t left = duration; left;) {
                    unsigned count = unsigned(std::min(uint64_t(blockSize), left));
                    block(position, count, current, .8f, upStart, duration); position += count; left -= count;
                }
                check([unit isRampComplete:up], "retarget endpoint");
                const auto mute = [unit rampToGain:0 durationFrames:duration];
                const uint64_t muteStart = position;
                for (uint64_t left = duration; left;) {
                    unsigned count = unsigned(std::min(uint64_t(blockSize), left));
                    block(position, count, .8f, 0, muteStart, duration, true); position += count; left -= count;
                }
                check([unit isRampComplete:mute], "silent input failed to advance envelope");
                const auto stale = [unit rampToGain:1 durationFrames:duration];
                [unit reset];
                block(position, 1, 0, 0, position, 0);
                check(![unit isRampComplete:stale], "reset resurrected stale token");
                [unit deallocateRenderResources];
                check(![unit isRampComplete:mute], "deallocated completion accepted");
                check([unit allocateRenderResourcesAndReturnError:&error], "reallocate");
                block(0, 1, 0, 0, 0, 0);
                check(![unit isRampComplete:stale], "reallocation reused token");
                [unit deallocateRenderResources];
                ++cases;
              }
            }
        }
    }
    printf("PASS: %u real AU cases, 44.1/48/96/192 kHz, mono/stereo, 8/16/24 ms, 1/127/512 frames; max residual %.9g FS\n", cases, maxResidual);
    puts("PASS: exact mute/completion, UI-independent ramps, retarget continuity, silent input and stale-token lifecycle");
} }
