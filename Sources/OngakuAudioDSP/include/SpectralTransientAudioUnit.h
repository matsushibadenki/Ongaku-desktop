#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface OngakuSpectralTransientAudioUnit : AUAudioUnit
+ (AVAudioUnitEffect *)makeNode;
- (void)setAmount:(float)amount;
@end
NS_ASSUME_NONNULL_END
