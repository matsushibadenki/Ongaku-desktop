#import "TruePeakAudioUnit.h"
#include "TruePeakDSP.hpp"
#include <memory>
#include <vector>
#include <array>
#include <cstring>

namespace {
struct TruePeakStorage {
    ongaku::TruePeakLimiter dsp;
    std::vector<float> input, output;
    std::vector<uint8_t> listBytes;
    unsigned channels = 0, capacity = 0;
    void clear() {
        capacity = channels = 0;
        std::vector<float>().swap(input); std::vector<float>().swap(output);
        std::vector<uint8_t>().swap(listBytes);
        dsp = ongaku::TruePeakLimiter();
    }
    bool allocate(unsigned ch, unsigned frames, double rate) {
        channels = ch; capacity = frames;
        try {
            input.assign(size_t(ch) * frames, 0); output.assign(size_t(ch) * frames, 0);
            listBytes.assign(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * ch, 0);
        } catch (...) { return false; }
        return dsp.prepare(ch, rate);
    }
    AUAudioUnitStatus render(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            unsigned count, AudioBufferList *data,
                            __unsafe_unretained AURenderPullInputBlock pull) noexcept {
        if (!pull) return kAudioUnitErr_NoConnection;
        if (!capacity || count > capacity) return kAudioUnitErr_TooManyFramesToProcess;
        if (!data || data->mNumberBuffers != channels) return kAudioUnitErr_FormatNotSupported;
        if (!count) return noErr;
        auto *list = reinterpret_cast<AudioBufferList *>(listBytes.data());
        list->mNumberBuffers = channels;
        const unsigned bytes = count * sizeof(float);
        for (unsigned ch = 0; ch < channels; ++ch) {
            if (data->mBuffers[ch].mData && data->mBuffers[ch].mDataByteSize < bytes) return kAudioUnitErr_InvalidPropertyValue;
            list->mBuffers[ch] = {1, bytes, input.data() + size_t(ch) * capacity};
        }
        AudioUnitRenderActionFlags inputFlags = 0;
        const auto status = pull(&inputFlags, time, count, 0, list);
        if (status != noErr) return status;
        if (list->mNumberBuffers != channels) return kAudioUnitErr_FormatNotSupported;
        std::array<const float *, 8> sources{};
        std::array<float *, 8> destinations{};
        for (unsigned ch = 0; ch < channels; ++ch) {
            auto *owned = input.data() + size_t(ch) * capacity;
            const auto &buffer = list->mBuffers[ch];
            if (inputFlags & kAudioUnitRenderAction_OutputIsSilence) std::memset(owned, 0, bytes);
            else {
                if (!buffer.mData || buffer.mDataByteSize < bytes) return kAudioUnitErr_InvalidPropertyValue;
                if (buffer.mData != owned) std::memcpy(owned, buffer.mData, bytes);
            }
            sources[ch] = owned;
            destinations[ch] = output.data() + size_t(ch) * capacity;
        }
        dsp.process(sources.data(), destinations.data(), count);
        for (unsigned ch = 0; ch < channels; ++ch) {
            auto &buffer = data->mBuffers[ch];
            if (!buffer.mData) buffer.mData = destinations[ch];
            else std::memcpy(buffer.mData, destinations[ch], bytes);
            buffer.mNumberChannels = 1; buffer.mDataByteSize = bytes;
        }
        // Silence at the input can still have delayed audio/release tails.
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
};
}
@implementation OngakuTruePeakAudioUnit {
    AUAudioUnitBusArray *_inputs, *_outputs;
    std::unique_ptr<TruePeakStorage> _storage;
}
+ (AVAudioUnitEffect *)makeNode {
    static dispatch_once_t once;
    AudioComponentDescription description = {kAudioUnitType_Effect, 'otpk', 'Ongk', 0, 0};
    dispatch_once(&once, ^{ [AUAudioUnit registerSubclass:self asComponentDescription:description name:@"Ongaku:Final True Peak" version:1]; });
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:description];
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (!self) return nil;
    _storage = std::make_unique<TruePeakStorage>();
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    AUAudioUnitBus *input = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    AUAudioUnitBus *output = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!input || !output) return nil;
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[input]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[output]];
    self.maximumFramesToRender = 4096;
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (BOOL)canProcessInPlace { return NO; }
- (NSTimeInterval)latency { return double(std::max(32, int(std::ceil(_outputs[0].format.sampleRate * 0.004))) + ongaku::TruePeakLimiter::radius) / _outputs[0].format.sampleRate; }
- (NSTimeInterval)tailTime { return self.latency; }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    AVAudioFormat *format = _outputs[0].format;
    if (format.commonFormat != AVAudioPCMFormatFloat32 || format.interleaved || format.channelCount == 0 || format.channelCount > 8 ||
        !std::isfinite(format.sampleRate) || format.sampleRate < 8000 || format.sampleRate > 384000 ||
        self.maximumFramesToRender == 0 || self.maximumFramesToRender > 65536 || ![format isEqual:_inputs[0].format]) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    if (!_storage->allocate(format.channelCount, self.maximumFramesToRender, format.sampleRate)) {
        _storage->clear();
        [super deallocateRenderResources];
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FailedInitialization userInfo:nil];
        return NO;
    }
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; _storage->clear(); }
- (void)reset { [super reset]; _storage->dsp.reset(); }
- (AUInternalRenderBlock)internalRenderBlock {
    TruePeakStorage *storage = _storage.get();
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, AUAudioFrameCount count,
                             NSInteger bus, AudioBufferList *data, const AURenderEvent *events,
                             __unsafe_unretained AURenderPullInputBlock pull) {
        if (bus != 0) return kAudioUnitErr_InvalidElement;
        return storage->render(flags, time, count, data, pull);
    };
}
@end
