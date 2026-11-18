// SPDX-License-Identifier: GPL-3.0-only
// BridgeEngine: system audio -> LDAC -> headphones, start to finish.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BridgeState) {
    BridgeStateIdle,
    BridgeStateConnecting,
    BridgeStateStreaming,
    BridgeStateStopping,
};

@interface BridgeEngine : NSObject

// Delivered on the main queue. message is a short human-readable status or error.
// Every failure leaves the engine Idle with the headphones handed back to macOS.
@property(nonatomic, copy, nullable) void (^onStateChange)(BridgeState state, NSString *message);
@property(atomic, readonly) BridgeState state;

// quality: 0 = HQ (990 kbps), 1 = SQ (660), 2 = MQ (330).
// sampleRate: 44100, 48000, 88200 or 96000. The Mac's built-in output is switched
// to this rate while streaming (capture is clocked by it) and restored afterwards.
- (void)startWithAddress:(NSString *)address quality:(int)quality sampleRate:(int)sampleRate;
- (void)stop;

// If the previous run crashed or was killed while streaming, hands the headphones
// back to macOS and restores the speakers' sample rate. Call once at launch.
- (void)recoverFromPreviousRun;

// Blocks until the engine is idle again (for clean shutdown on quit).
- (void)stopAndWait;

// One-line throughput / level summary for diagnostics. Call from the main thread.
- (NSString *)statistics;

@end

NS_ASSUME_NONNULL_END
