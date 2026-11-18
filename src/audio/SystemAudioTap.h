// SPDX-License-Identifier: GPL-3.0-only
// SystemAudioTap: captures everything macOS plays (Core Audio process tap, macOS
// 14.2+) and mutes it on the local output while the tap exists.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Receives interleaved stereo float32 frames on the Core Audio IO thread.
typedef void (^SystemAudioHandler)(const float *frames, uint32_t count);

@interface SystemAudioTap : NSObject

// Briefly runs an unmuted tap so macOS asks for the "system audio recording"
// permission up front, rather than in the middle of taking over the headphones.
+ (void)requestPermission;

// Creates the tap. From this point all system audio is muted on the local output,
// so nothing blares out of the speakers while the headphones are being taken over.
- (nullable instancetype)initWithError:(NSError **)error;

// Starts delivering audio, clocked by whatever the default output device is now.
- (BOOL)startWithHandler:(SystemAudioHandler)handler error:(NSError **)error;

// Sample rate of the delivered audio; valid after start.
@property(nonatomic, readonly) double sampleRate;

// Stops delivery and removes the tap (unmuting local output).
- (void)stop;

@end

NS_ASSUME_NONNULL_END
