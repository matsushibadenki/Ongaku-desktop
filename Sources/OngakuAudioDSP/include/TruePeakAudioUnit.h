#import "GainEnvelopeAudioUnit.h"
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Audio graph changes can invalidate a render clock between observation and
/// conversion. Returns nil if AVFoundation raises an Objective-C exception.
FOUNDATION_EXPORT AVAudioTime * _Nullable OngakuSafePlayerTime(
    AVAudioPlayerNode *node, AVAudioTime *nodeTime);
/// One-input final-output protector; connect at the actual device render rate.
@interface OngakuTruePeakAudioUnit : AUAudioUnit
+ (AVAudioUnitEffect *)makeNode;
@end
NS_ASSUME_NONNULL_END
#import "SpectralTransientAudioUnit.h"
