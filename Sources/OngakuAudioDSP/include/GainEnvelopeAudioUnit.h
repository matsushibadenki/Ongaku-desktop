#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Candidate mono/stereo sample-accurate attenuation stage. One control writer.
/// Allocate/reset while render is quiescent. Starts and resets muted.
@interface OngakuGainEnvelopeAudioUnit : AUAudioUnit
+ (AVAudioUnitEffect *)makeNode;
/// Next successful render block starts a cosine ramp from the last rendered gain.
/// Frames=0 explicitly selects the target. Token 0 means resources are unavailable.
- (uint64_t)rampToGain:(float)gain durationFrames:(uint64_t)frames;
/// True only for the latest token after the endpoint was actually rendered.
- (BOOL)isRampComplete:(uint64_t)token;
@end
NS_ASSUME_NONNULL_END
