#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
NS_ASSUME_NONNULL_BEGIN
// Compiled in topological order. References must point to earlier steps.
// Kinds: application=0, gain=1, lowpass=2, delay=3, mixer=4, meter=5, recorder=6, device=7, waveform=8, equalizer=9, compressor=10, limiter=11.
// application.p0: input gain 1...10; applies before all outgoing branches.
// device.p0: monitoring gain 0...1; applies only to the terminal monitor output.
typedef struct {
    UInt32 kind;
    SInt32 inputA;
    SInt32 inputB;
    BOOL bypassed;
    float p0, p1, p2, p3, p4;
    float eqGains[10];
} OngakuAudioRouteStep;
FOUNDATION_EXPORT BOOL OngakuValidateAudioRoute(const OngakuAudioRouteStep *steps, NSUInteger count);

/// Per-session, preallocated stereo DSP. Configure topology before starting IO;
/// publish parameters from one control thread, process from one audio thread.
/// Output is always stereo interleaved Float32.
@interface OngakuAudioRoute : NSObject
- (nullable instancetype)initWithSteps:(const OngakuAudioRouteStep *)steps
                                count:(NSUInteger)count sampleRate:(double)rate error:(NSError **)error;
- (OSStatus)processFrames:(UInt32)frames input:(const AudioBufferList *)input
                  output:(AudioBufferList *)output;
- (OSStatus)processFrames:(UInt32)frames input:(const AudioBufferList *)input
                recording:(nullable AudioBufferList *)recording monitor:(nullable AudioBufferList *)monitor;
// Single control-thread producer; preserves topology and DSP history.
- (BOOL)updateParameters:(const OngakuAudioRouteStep *)steps count:(NSUInteger)count error:(NSError **)error;
// Copies the newest count min/max pairs into a buffer of 2 * count floats (count <= 128).
- (void)copyWaveformAtStep:(NSUInteger)index into:(float *)pairs count:(NSUInteger)count;
- (float)peakAtStep:(NSUInteger)index;
// Atomically consumes the over-full-scale flag, including transients between UI polls.
- (BOOL)takeClippingAtStep:(NSUInteger)index;
@end

/// Bounded SPSC stereo bridge. One capture producer and one output consumer.
/// No allocations in append/render. Interpolates to the device rate and
/// corrects small independent clock drift around the target fill.
@interface OngakuMonitorBuffer : NSObject
- (instancetype)initWithSampleRate:(double)rate;
- (instancetype)initWithSampleRate:(double)rate renderRate:(double)renderRate;
- (BOOL)appendFrames:(UInt32)frames samples:(const float *)samples;
- (void)renderFrames:(UInt32)frames samples:(float *)samples;
@property(nonatomic, readonly) uint64_t renderedFrames;
@property(nonatomic, readonly) uint64_t underruns;
@end

NS_ASSUME_NONNULL_END
