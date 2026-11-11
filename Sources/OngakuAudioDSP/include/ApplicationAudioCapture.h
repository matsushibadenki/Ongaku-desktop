#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import "AudioRoutingDSP.h"
NS_ASSUME_NONNULL_BEGIN

/// Single-producer async PCM writer. Create/finish off the audio thread; finish only
/// after the producer is stopped. No allocation, locks, or file IO in appendFrames.
@interface OngakuCaptureWriter : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url format:(AudioStreamBasicDescription)format error:(NSError **)error;
- (nullable instancetype)initWithURL:(NSURL *)url format:(AudioStreamBasicDescription)format bitDepth:(UInt32)bits sampleRate:(double)rate info:(NSData *)info id3:(NSData *)id3 error:(NSError **)error;
- (void)appendFrames:(UInt32)frames buffers:(const AudioBufferList *)buffers;
- (OSStatus)finish;
@property(nonatomic, readonly) OSStatus status;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) float peak;
@end

API_AVAILABLE(macos(14.2))
@interface OngakuApplicationAudioCapture : NSObject
- (BOOL)setRouteSteps:(const OngakuAudioRouteStep *)steps count:(NSUInteger)count error:(NSError **)error;
// Single control-thread producer; preserves topology and DSP history.
- (BOOL)updateParameters:(const OngakuAudioRouteStep *)steps count:(NSUInteger)count error:(NSError **)error;
- (void)copyWaveformAtStep:(NSUInteger)index into:(float *)pairs count:(NSUInteger)count;
- (float)peakAtStep:(NSUInteger)index;
// Atomically consumes the over-full-scale flag, including transients between UI polls.
- (BOOL)takeClippingAtStep:(NSUInteger)index;
- (BOOL)startProcesses:(NSArray<NSNumber *> *)processes URL:(nullable NSURL *)url error:(NSError **)error;
- (BOOL)setRecordingBitDepth:(UInt32)bits sampleRate:(double)rate info:(NSData *)info id3:(NSData *)id3 error:(NSError **)error;
- (BOOL)setMonitorSampleRate:(double)rate error:(NSError **)error;
- (BOOL)setOutputDeviceUID:(NSString *)uid error:(NSError **)error;
@property(nonatomic, readonly) uint64_t monitoredFrames;
@property(nonatomic, readonly) uint64_t monitorUnderruns;
- (OSStatus)stop;
@property(nonatomic, readonly) OSStatus status;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) float peak;
@property(nonatomic, readonly) BOOL formatIsCurrent;
@end
NS_ASSUME_NONNULL_END
