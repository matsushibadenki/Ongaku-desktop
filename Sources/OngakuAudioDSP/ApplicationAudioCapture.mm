#import "ApplicationAudioCapture.h"
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <AudioToolbox/AudioToolbox.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <array>

static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<OSStatus>::is_always_lock_free);

static NSError *CaptureError(OSStatus status) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}
static AudioObjectPropertyAddress CaptureAddress(AudioObjectPropertySelector selector) {
    return {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

@implementation OngakuCaptureWriter {
    ExtAudioFileRef _file;
    AudioStreamBasicDescription _format;
    double _diskBytesPerInputFrame;
    std::atomic<OSStatus> _status;
    std::atomic<uint64_t> _frames;
    std::atomic<float> _peak;
}
- (instancetype)initWithURL:(NSURL *)url format:(AudioStreamBasicDescription)format error:(NSError **)error {
    return [self initWithURL:url format:format bitDepth:32 sampleRate:0 info:[NSData data] id3:[NSData data] error:error];
}
- (instancetype)initWithURL:(NSURL *)url format:(AudioStreamBasicDescription)format bitDepth:(UInt32)bits sampleRate:(double)rate info:(NSData *)info id3:(NSData *)id3 error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _format = format;
    _status.store(noErr); _frames.store(0); _peak.store(0);
    const bool planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if ((bits != 16 && bits != 24 && bits != 32) || (rate != 0 && rate != 44100 && rate != 48000 && rate != 88200 && rate != 96000 && rate != 176400 && rate != 192000) || (info.length > 16384 || id3.length > 16384)
        || format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat)
        || (format.mFormatFlags & kAudioFormatFlagIsBigEndian) || format.mBitsPerChannel != 32
        || format.mChannelsPerFrame < 1 || format.mChannelsPerFrame > 2
        || format.mBytesPerFrame != sizeof(float) * (planar ? 1 : format.mChannelsPerFrame)
        || !std::isfinite(format.mSampleRate) || format.mSampleRate <= 0) {
        if (error) *error = CaptureError(kAudioFormatUnsupportedDataFormatError);
        return nil;
    }
    // Conversion runs in the async writer, keeping the audio callback Float32.
    auto diskFormat = format;
    diskFormat.mSampleRate = rate == 0 ? format.mSampleRate : rate;
    diskFormat.mBitsPerChannel = bits;
    diskFormat.mFormatFlags = (bits == 32 ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked;
    diskFormat.mBytesPerFrame = (bits / 8) * format.mChannelsPerFrame;
    _diskBytesPerInputFrame = diskFormat.mSampleRate / format.mSampleRate * diskFormat.mBytesPerFrame;
    diskFormat.mBytesPerPacket = diskFormat.mBytesPerFrame;
    diskFormat.mFramesPerPacket = 1;
    // No erase flag: never overwrite an existing recording.
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileWAVEType,
                                               &diskFormat, nullptr, 0, &_file);
    if (!status) status = ExtAudioFileSetProperty(_file, kExtAudioFileProperty_ClientDataFormat, sizeof(format), &format);
    if (!status && info.length) {
        AudioFileID audioFile = nullptr; UInt32 size = sizeof(audioFile);
        status = ExtAudioFileGetProperty(_file, kExtAudioFileProperty_AudioFile, &size, &audioFile);
        if (!status) status = AudioFileSetUserData(audioFile, 'LIST', 0, (UInt32)info.length, info.bytes);
    }
    if (!status && id3.length) {
        AudioFileID audioFile = nullptr; UInt32 size = sizeof(audioFile);
        status = ExtAudioFileGetProperty(_file, kExtAudioFileProperty_AudioFile, &size, &audioFile);
        if (!status) status = AudioFileSetUserData(audioFile, 'id3 ', 0, (UInt32)id3.length, id3.bytes);
    }
    // Prime Apple's bounded async ring before entering the realtime callback.
    if (!status) status = ExtAudioFileWriteAsync(_file, 0, nullptr);
    if (status) {
        if (error) *error = CaptureError(status);
        if (_file) { ExtAudioFileDispose(_file); _file = nullptr; }
        return nil;
    }
    return self;
}
- (void)appendFrames:(UInt32)frames buffers:(const AudioBufferList *)buffers {
    if (!_file || _status.load(std::memory_order_relaxed) != noErr || frames == 0) return;
    const bool planar = (_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 count = planar ? _format.mChannelsPerFrame : 1;
    if (!buffers || buffers->mNumberBuffers != count) {
        _status.store(kAudio_ParamError); return;
    }
    float peak = 0;
    for (UInt32 i = 0; i < count; ++i) {
        const auto &buffer = buffers->mBuffers[i];
        if (!buffer.mData || buffer.mNumberChannels != (planar ? 1 : _format.mChannelsPerFrame)
            || uint64_t(frames) * _format.mBytesPerFrame > buffer.mDataByteSize) {
            _status.store(kAudio_ParamError); return;
        }
        const auto *samples = static_cast<const float *>(buffer.mData);
        const size_t sampleCount = size_t(frames) * (planar ? 1 : _format.mChannelsPerFrame);
        for (size_t sample = 0; sample < sampleCount; ++sample) {
            if (!std::isfinite(samples[sample])) { _status.store(kAudio_ParamError); return; }
            peak = std::max(peak, std::abs(samples[sample]));
        }
    }
    const auto total = _frames.load(std::memory_order_relaxed) + frames;
    // Stop before the RIFF 4 GiB limit; report a partial recording, never wrap.
    if (std::ceil(total * _diskBytesPerInputFrame) > 3'800'000'000ULL) {
        _status.store(kAudioFileDoesNotAllow64BitDataSizeError); return;
    }
    const OSStatus result = ExtAudioFileWriteAsync(_file, frames, buffers);
    if (result) _status.store(result);
    else _frames.store(total, std::memory_order_relaxed);
    _peak.store(peak, std::memory_order_relaxed);
}
- (OSStatus)finish {
    if (_file) {
        const auto result = ExtAudioFileDispose(_file); // flush queued writes and finalize WAV
        _file = nullptr;
        if (result && !_status.load()) _status.store(result);
    }
    return _status.load();
}
- (OSStatus)status { return _status.load(); }
- (double)duration { return _format.mSampleRate > 0 ? double(_frames.load()) / _format.mSampleRate : 0; }
- (float)peak { return _peak.load(); }
- (void)dealloc { [self finish]; }
@end

// Each session owns an explicitly selected output unit; system output settings
// and the library player are untouched. All setup occurs before capture IO.
@interface OngakuCaptureOutput : NSObject
- (instancetype)initWithDevice:(AudioDeviceID)device rate:(double)rate error:(NSError **)error;
- (OSStatus)start;
- (void)stop;
- (BOOL)isCurrent;
@property(nonatomic, readonly) OngakuMonitorBuffer *buffer;
@end
@implementation OngakuCaptureOutput {
    AudioUnit _unit;
    AudioDeviceID _deviceID;
    double _deviceRate;
    OngakuMonitorBuffer *_buffer;
}
static OSStatus OutputRender(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    OngakuMonitorBuffer *buffer = (__bridge OngakuMonitorBuffer *)context;
    if (!data) return kAudio_ParamError;
    if (data->mNumberBuffers != 1 || data->mBuffers[0].mNumberChannels != 2
        || !data->mBuffers[0].mData || data->mBuffers[0].mDataByteSize < uint64_t(frames)*8) {
        for (UInt32 b=0;b<data->mNumberBuffers;++b) if(data->mBuffers[b].mData)
            memset(data->mBuffers[b].mData,0,data->mBuffers[b].mDataByteSize);
        return kAudio_ParamError;
    }
    [buffer renderFrames:frames samples:static_cast<float *>(data->mBuffers[0].mData)];
    return noErr;
}
- (instancetype)initWithDevice:(AudioDeviceID)device rate:(double)rate error:(NSError **)error {
    self = [super init]; if (!self) return nil;
    _deviceID = device;
    auto address = CaptureAddress(kAudioDevicePropertyNominalSampleRate);
    UInt32 size=sizeof(_deviceRate);
    OSStatus status=AudioObjectGetPropertyData(device,&address,0,nullptr,&size,&_deviceRate);
    AudioComponentDescription desc = {kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
    auto component=AudioComponentFindNext(nullptr,&desc);
    if (!status) status = component ? AudioComponentInstanceNew(component,&_unit) : kAudio_ParamError;
    UInt32 off=0,on=1;
    if (!status) status=AudioUnitSetProperty(_unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&off,sizeof(off));
    if (!status) status=AudioUnitSetProperty(_unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&on,sizeof(on));
    if (!status) status=AudioUnitSetProperty(_unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,sizeof(device));
    AudioStreamBasicDescription format={_deviceRate,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,8,1,8,2,32,0};
    if (!status) status=AudioUnitSetProperty(_unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,sizeof(format));
    UInt32 maximumFrames=4096;
    if (!status) status=AudioUnitSetProperty(_unit,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maximumFrames,sizeof(maximumFrames));
    _buffer=[[OngakuMonitorBuffer alloc] initWithSampleRate:rate renderRate:_deviceRate];
    AURenderCallbackStruct callback={OutputRender,(__bridge void *)_buffer};
    if (!status) status=AudioUnitSetProperty(_unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback));
    if (!status) status=AudioUnitInitialize(_unit);
    if (status) { if(error)*error=CaptureError(status); [self stop]; return nil; }
    return self;
}
- (OngakuMonitorBuffer *)buffer { return _buffer; }
- (OSStatus)start { return AudioOutputUnitStart(_unit); }
- (void)stop { if (_unit) { AudioOutputUnitStop(_unit); AudioUnitUninitialize(_unit); AudioComponentInstanceDispose(_unit); _unit=nullptr; } }
- (BOOL)isCurrent {
    UInt32 alive=0,size=sizeof(alive); auto address=CaptureAddress(kAudioDevicePropertyDeviceIsAlive);
    if(AudioObjectGetPropertyData(_deviceID,&address,0,nullptr,&size,&alive)||!alive)return NO;
    double rate=0;size=sizeof(rate);address=CaptureAddress(kAudioDevicePropertyNominalSampleRate);
    return AudioObjectGetPropertyData(_deviceID,&address,0,nullptr,&size,&rate)==noErr && rate==_deviceRate;
}
- (void)dealloc { [self stop]; }
@end

@implementation OngakuApplicationAudioCapture {
    AudioObjectID _tap;
    AudioObjectID _device;
    AudioDeviceIOProcID _proc;
    AudioStreamBasicDescription _format;
    OngakuCaptureWriter *_writer;
    OngakuAudioRoute *_route;
    std::array<OngakuAudioRouteStep,16> _routeSteps;
    NSUInteger _routeCount;
    std::array<float,8192> _routeOutput;
    std::atomic<OSStatus> _routeStatus;
    NSString *_outputUID;
    AudioDeviceID _outputID;
    double _monitorRate;
    double _previousOutputRate;
    OngakuCaptureOutput *_monitor;
    std::array<float,8192> _monitorOutput;
    std::atomic<uint64_t> _processedFrames;
    std::atomic<float> _sessionPeak;
    BOOL _records, _monitors;
    UInt32 _recordingBits; double _recordingRate; NSData *_recordingInfo; NSData *_recordingID3;

}
API_AVAILABLE(macos(14.2))
static OSStatus CaptureIO(AudioObjectID device, const AudioTimeStamp *now,
                          const AudioBufferList *input, const AudioTimeStamp *inputTime,
                          AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    OngakuApplicationAudioCapture *capture = (__bridge OngakuApplicationAudioCapture *)context;
    [capture consume:input];
    return noErr;
}
- (void)consume:(const AudioBufferList *)input {
    if (!input || !input->mNumberBuffers || !_format.mBytesPerFrame) return;
    const UInt32 bytes = input->mBuffers[0].mDataByteSize;
    if (bytes % _format.mBytesPerFrame) { _routeStatus.store(kAudio_ParamError); return; }
    const UInt32 frames = bytes / _format.mBytesPerFrame;
    if (!_route) { [_writer appendFrames:frames buffers:input]; return; }
    if (_routeStatus.load(std::memory_order_relaxed) != noErr) return;
    if (input->mNumberBuffers < 1 || input->mNumberBuffers > 2) { _routeStatus.store(kAudio_ParamError); return; }
    for (UInt32 offset = 0; offset < frames; offset += 4096) {
        const UInt32 count = std::min(UInt32(4096),frames-offset);
        struct { UInt32 count; AudioBuffer buffers[2]; } slice{};
        slice.count = input->mNumberBuffers;
        for (UInt32 b = 0; b < slice.count; ++b) {
            const auto buffer = input->mBuffers[b];
            const uint64_t end = uint64_t(offset+count)*_format.mBytesPerFrame;
            if (!buffer.mData || buffer.mDataByteSize < end) { _routeStatus.store(kAudio_ParamError); return; }
            slice.buffers[b] = {buffer.mNumberChannels,count*_format.mBytesPerFrame,
                               static_cast<char *>(buffer.mData)+offset*_format.mBytesPerFrame};
        }
        AudioBufferList output = {1, {{2,count*8,_routeOutput.data()}}};
        AudioBufferList monitor = {1, {{2,count*8,_monitorOutput.data()}}};
        const auto status = [_route processFrames:count input:reinterpret_cast<AudioBufferList *>(&slice)
                                      recording:_records ? &output : nullptr monitor:_monitors ? &monitor : nullptr];
        if (status) { _routeStatus.store(status); return; }
        if (_records) [_writer appendFrames:count buffers:&output];
        if (_monitors && ![_monitor.buffer appendFrames:count samples:_monitorOutput.data()]) {
            _routeStatus.store(kAudio_ParamError); return;
        }
        float peak=0;
        for(UInt32 f=0;f<count*2;++f) peak=std::max(peak,std::abs(_monitors ? _monitorOutput[f] : _routeOutput[f]));
        _sessionPeak.store(peak,std::memory_order_relaxed);
        _processedFrames.fetch_add(count,std::memory_order_relaxed);
    }
}
- (BOOL)setRouteSteps:(const OngakuAudioRouteStep *)steps count:(NSUInteger)count error:(NSError **)error {
    if (_tap || !OngakuValidateAudioRoute(steps,count)) {
        if (error) *error = CaptureError(kAudio_ParamError); return NO;
    }
    std::copy(steps,steps+count,_routeSteps.begin()); _routeCount = count;
    _records=NO; _monitors=NO;
    for(NSUInteger i=0;i<count;++i) { _records |= steps[i].kind==6; _monitors |= steps[i].kind==7; }
    return YES;
}
- (BOOL)updateParameters:(const OngakuAudioRouteStep *)steps count:(NSUInteger)count error:(NSError **)error {
    if (!_proc || !_route) { if (error) *error = CaptureError(kAudio_ParamError); return NO; }
    return [_route updateParameters:steps count:count error:error];
}
- (BOOL)setRecordingBitDepth:(UInt32)bits sampleRate:(double)rate info:(NSData *)info id3:(NSData *)id3 error:(NSError **)error {
    if (_tap || (bits != 16 && bits != 24 && bits != 32) || (rate != 0 && rate != 44100 && rate != 48000 && rate != 88200 && rate != 96000 && rate != 176400 && rate != 192000) || (info.length > 16384 || id3.length > 16384)) {
        if (error) *error = CaptureError(kAudio_ParamError); return NO;
    }
    _recordingBits = bits; _recordingRate = rate; _recordingInfo = [info copy]; _recordingID3 = [id3 copy]; return YES;
}
- (BOOL)setMonitorSampleRate:(double)rate error:(NSError **)error {
    if (_tap || !std::isfinite(rate) || (rate != 0 && (rate < 44100 || rate > 192000))) {
        if (error) *error = CaptureError(kAudio_ParamError);
        return NO;
    }
    _monitorRate = rate;
    return YES;
}
- (BOOL)setOutputDeviceUID:(NSString *)uid error:(NSError **)error {
    if (_tap || uid.length==0) { if(error)*error=CaptureError(kAudio_ParamError); return NO; }
    CFStringRef value=(__bridge CFStringRef)uid;
    auto address=CaptureAddress(kAudioHardwarePropertyTranslateUIDToDevice); UInt32 size=sizeof(_outputID);
    OSStatus status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,sizeof(value),&value,&size,&_outputID);
    if(status || !_outputID) { if(error)*error=CaptureError(status ?: kAudioHardwareBadDeviceError); return NO; }
    _outputUID=[uid copy]; return YES;
}
- (uint64_t)monitoredFrames { return _monitor.buffer.renderedFrames; }
- (uint64_t)monitorUnderruns { return _monitor.buffer.underruns; }
- (void)copyWaveformAtStep:(NSUInteger)index into:(float *)pairs count:(NSUInteger)count {
    [_route copyWaveformAtStep:index into:pairs count:count];
}
- (float)peakAtStep:(NSUInteger)index { return [_route peakAtStep:index]; }
- (BOOL)takeClippingAtStep:(NSUInteger)index { return [_route takeClippingAtStep:index]; }
- (BOOL)startProcesses:(NSArray<NSNumber *> *)processes URL:(NSURL *)url error:(NSError **)error {
    if (_tap || _device || processes.count == 0 || (_monitors && !_outputID) || ((_records || !_routeCount) && !url)) {
        if (error) *error = CaptureError(kAudio_ParamError);
        return NO;
    }
    if (_monitors && _monitorRate > 0) {
        auto address = CaptureAddress(kAudioDevicePropertyNominalSampleRate);
        Float64 current = 0;
        UInt32 size = sizeof(current);
        OSStatus rateStatus = AudioObjectGetPropertyData(_outputID, &address, 0, nullptr, &size, &current);
        if (!rateStatus && current != _monitorRate) {
            rateStatus = AudioObjectSetPropertyData(_outputID, &address, 0, nullptr, sizeof(_monitorRate), &_monitorRate);
            if (!rateStatus) {
                _previousOutputRate = current;
                rateStatus = AudioObjectGetPropertyData(_outputID, &address, 0, nullptr, &size, &current);
                if (!rateStatus && current != _monitorRate) rateStatus = kAudioFormatUnsupportedDataFormatError;
            }
        }
        if (rateStatus) {
            [self stop];
            if (error) *error = CaptureError(rateStatus);
            return NO;
        }
    }
    CATapDescription *description = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
    description.name = @"Ongaku Application Audio";
    description.privateTap = YES;
    description.muteBehavior = _monitors ? CATapMutedWhenTapped : CATapUnmuted;
    OSStatus status = AudioHardwareCreateProcessTap(description, &_tap);
    if (!status) {
        auto address = CaptureAddress(kAudioTapPropertyFormat);
        UInt32 size = sizeof(_format);
        status = AudioObjectGetPropertyData(_tap, &address, 0, nullptr, &size, &_format);
    }
    if (!status) {
        NSDictionary *device = @{
            @kAudioAggregateDeviceNameKey: @"Ongaku Application Audio",
            @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceTapAutoStartKey: @NO,
            @kAudioAggregateDeviceTapListKey: @[@{
                @kAudioSubTapUIDKey: description.UUID.UUIDString,
                @kAudioSubTapDriftCompensationKey: @YES
            }]
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)device, &_device);
    }
    if (!status) {
        auto writerFormat = _format;
        if (_routeCount) {
            if (_format.mFormatID != kAudioFormatLinearPCM || !(_format.mFormatFlags & kAudioFormatFlagIsFloat)
                || (_format.mFormatFlags & kAudioFormatFlagIsBigEndian) || _format.mBitsPerChannel != 32
                || _format.mChannelsPerFrame != 2
                || _format.mBytesPerFrame != ((_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 4 : 8)) {
                if (error) *error = CaptureError(kAudioFormatUnsupportedDataFormatError);
                [self stop]; return NO;
            }
            _route = [[OngakuAudioRoute alloc] initWithSteps:_routeSteps.data() count:_routeCount sampleRate:_format.mSampleRate error:error];
            if (!_route) { [self stop]; return NO; }
            _routeStatus.store(noErr);
            writerFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            writerFormat.mBytesPerFrame = 8; writerFormat.mBytesPerPacket = 8; writerFormat.mFramesPerPacket = 1;
        }
        if (_records || !_routeCount) {
            _writer = [[OngakuCaptureWriter alloc] initWithURL:url format:writerFormat bitDepth:_recordingBits ?: 32 sampleRate:_recordingRate info:_recordingInfo ?: [NSData data] id3:_recordingID3 ?: [NSData data] error:error];
            if (!_writer) { [self stop]; return NO; }
        }
        if (_monitors) {
            _monitor=[[OngakuCaptureOutput alloc] initWithDevice:_outputID rate:_format.mSampleRate error:error];
            if (!_monitor) { [self stop]; return NO; }
            status=[_monitor start];
            if(status) { if(error)*error=CaptureError(status); [self stop]; return NO; }
        }
        status = AudioDeviceCreateIOProcID(_device, CaptureIO, (__bridge void *)self, &_proc);
    }
    if (!status) status = AudioDeviceStart(_device, _proc);
    if (status) {
        if (error) *error = CaptureError(status);
        [self stop];
        return NO;
    }
    return YES;
}
- (OSStatus)stop {
    OSStatus status = noErr;
    if (_proc) {
        status = AudioDeviceStop(_device, _proc);
        const auto result = AudioDeviceDestroyIOProcID(_device, _proc);
        if (!status) status = result;
        _proc = nullptr;
    }
    [_monitor stop];
    if (_device) { AudioHardwareDestroyAggregateDevice(_device); _device = 0; }
    if (_tap) { AudioHardwareDestroyProcessTap(_tap); _tap = 0; }
    if (_previousOutputRate > 0) {
        auto address = CaptureAddress(kAudioDevicePropertyNominalSampleRate);
        Float64 current = 0;
        UInt32 size = sizeof(current);
        auto rateStatus = AudioObjectGetPropertyData(_outputID, &address, 0, nullptr, &size, &current);
        if (!rateStatus && current == _monitorRate)
            rateStatus = AudioObjectSetPropertyData(_outputID, &address, 0, nullptr, sizeof(_previousOutputRate), &_previousOutputRate);
        _previousOutputRate = 0;
        if (!status) status = rateStatus;
    }
    const auto result = [_writer finish];
    return status ?: (_routeStatus.load() ?: result);
}
- (BOOL)formatIsCurrent {
    if (!_tap || (_monitors && ![_monitor isCurrent])) return NO;
    if (_monitors) {
        CFStringRef uid=(__bridge CFStringRef)_outputUID; AudioDeviceID currentID=0;
        auto address=CaptureAddress(kAudioHardwarePropertyTranslateUIDToDevice); UInt32 size=sizeof(currentID);
        if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,sizeof(uid),&uid,&size,&currentID) || currentID!=_outputID) return NO;
    }
    AudioStreamBasicDescription current = {};
    UInt32 size = sizeof(current);
    auto address = CaptureAddress(kAudioTapPropertyFormat);
    if (AudioObjectGetPropertyData(_tap, &address, 0, nullptr, &size, &current)) return NO;
    return current.mSampleRate == _format.mSampleRate && current.mFormatID == _format.mFormatID
        && current.mFormatFlags == _format.mFormatFlags && current.mBytesPerFrame == _format.mBytesPerFrame
        && current.mChannelsPerFrame == _format.mChannelsPerFrame && current.mBitsPerChannel == _format.mBitsPerChannel;
}
- (OSStatus)status { return _routeStatus.load() ?: _writer.status; }
- (double)duration { return _routeCount && _format.mSampleRate > 0 ? double(_processedFrames.load())/_format.mSampleRate : _writer.duration; }
- (float)peak { return _routeCount ? _sessionPeak.load() : _writer.peak; }
- (void)dealloc { [self stop]; }
@end
