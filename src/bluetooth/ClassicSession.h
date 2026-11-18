// SPDX-License-Identifier: GPL-3.0-only
// ClassicSession: a client of bluetoothd's private classic-Bluetooth XPC service
// (com.apple.server.bluetooth.classic.xpc). It can resolve a paired device, take its
// link away from the system audio stack, and open raw L2CAP channels whose socket
// file descriptors bluetoothd hands back to us.
//
// Message ids and argument keys were recovered from Lucid's LPCClassicSession and
// checked against bluetoothd on macOS 15.8 (Intel). See docs/protocol.md.
//
// The blocking methods must not be called on the main thread. Callbacks run on the
// session's private queue.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static const uint16_t kPSMAVDTP = 0x19;

// An open L2CAP channel. Owns its socket and closes it on dealloc.
@interface L2CAPChannel : NSObject
@property(nonatomic, readonly) int fd;
@property(nonatomic, readonly) uint16_t cid;
@property(nonatomic, readonly) uint16_t outMTU;
@end

@interface ClassicSession : NSObject

// Checks in with bluetoothd and waits until the controller reports powered on.
- (nullable instancetype)initWithName:(NSString *)name error:(NSError **)error;

// Resolves a paired device by address ("aa:bb:cc:dd:ee:ff" or "aa-bb-…"). Also
// reports whether bluetoothd currently considers it connected.
- (nullable NSUUID *)lookupAddress:(NSString *)address connected:(nullable BOOL *)connected error:(NSError **)error;

// Opens an L2CAP channel on a device bluetoothd already has a link to.
- (nullable L2CAPChannel *)openChannelTo:(NSUUID *)device psm:(uint16_t)psm error:(NSError **)error;

// Drops the system's link to the device and brings it back up, opening our own AVDTP
// signaling channel the moment the ACL exists, before bluetoothd's A2DP service
// (which starts roughly half a second later) can claim PSM 25.
- (nullable L2CAPChannel *)takeOverAVDTP:(NSUUID *)device error:(NSError **)error;

- (void)closeChannelTo:(NSUUID *)device psm:(uint16_t)psm;

// Force-disconnects the device, then reconnects it normally so macOS restores its
// own A2DP/HFP/AVRCP profiles. Returns NO if bluetoothd didn't report it reconnected.
- (BOOL)handBack:(NSUUID *)device;

// YES once the connection to bluetoothd has broken (e.g. bluetoothd restarted). The
// session can't be used after that; channels it opened are gone too.
@property(atomic, readonly) BOOL invalidated;

// Called with the PSM of a channel to the device in use that bluetoothd reports closed.
@property(atomic, copy, nullable) void (^channelClosed)(uint16_t psm);

// Called once if the connection to bluetoothd breaks.
@property(atomic, copy, nullable) void (^onInvalidated)(void);

@end

NS_ASSUME_NONNULL_END
