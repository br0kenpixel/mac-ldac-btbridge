// SPDX-License-Identifier: GPL-3.0-only
// A2DPLink: an A2DP source stream to one sink, built on a ClassicSession-provided
// AVDTP signaling channel. Configures the sink's LDAC endpoint, opens the media
// transport channel and keeps answering the sink's signaling while streaming.

#import <Foundation/Foundation.h>

#import "ClassicSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2DPLink : NSObject

- (instancetype)initWithDevice:(NSUUID *)device signaling:(L2CAPChannel *)signaling;

// Finds the sink's LDAC endpoint and brings a stream at sampleRate to STREAMING.
- (BOOL)startLDACAtRate:(int)sampleRate error:(NSError **)error;

// Valid once started.
@property(nonatomic, readonly) int mediaFd;
@property(nonatomic, readonly) uint16_t mediaMTU;

// Becomes YES if the sink closes or suspends the stream on its own.
@property(atomic, readonly) BOOL interrupted;

// Suspends and closes the stream and releases both channels.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
