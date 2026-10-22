#import "GainEnvelopeAudioUnit.h"
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
/// One-input final-output protector; connect at the actual device render rate.
@interface OngakuTruePeakAudioUnit : AUAudioUnit
+ (AVAudioUnitEffect *)makeNode;
@end
NS_ASSUME_NONNULL_END
