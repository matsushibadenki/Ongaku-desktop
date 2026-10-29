#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface OngakuSpectralTransientAudioUnit : AUAudioUnit
+ (nullable AVAudioUnitEffect *)makeNode;
- (void)setAmount:(float)amount;
@end
NS_ASSUME_NONNULL_END
