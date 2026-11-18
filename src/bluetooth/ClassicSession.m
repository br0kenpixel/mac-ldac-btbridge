// SPDX-License-Identifier: GPL-3.0-only
#import "ClassicSession.h"

#include <sys/socket.h>
#include <unistd.h>
#include <xpc/xpc.h>

enum {
    kMsgCheckIn = 1,
    kMsgPairingAgentRegister = 10,
    kMsgRetrievePairedDevices = 12,
    kEvtStateUpdated = 6,
    kEvtChannelOpened = 27,
    kEvtChannelClosed = 28,
    kMsgOpenChannel = 29,
    kMsgCloseChannel = 30,
    kMsgRetrievePeerWithAddress = 44,
    kMsgConnectPeer = 45,
    kMsgCancelPeerConnection = 46,
    kEvtPeerConnected = 55,
    kEvtPeerDisconnected = 57,
};

static const int64_t kStatePoweredOn = 5;
static const int64_t kInternalStateConnected = 2;
static const int64_t kPairingStatePaired = 1;
// bluetoothd answers an open for a device without an ACL with this result.
static const int64_t kResultNoLink = 1804;
// How long the take-over keeps polling for the link to come back.
static const double kTakeOverWindowSeconds = 15;

static NSError *makeError(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static NSError *makeError(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:@"ClassicSession" code:1 userInfo:@{NSLocalizedDescriptionKey : msg}];
}

static xpc_object_t emptyDict(void) { return xpc_dictionary_create(NULL, NULL, 0); }

static xpc_object_t peerArgs(NSUUID *device) {
    uuid_t u;
    [device getUUIDBytes:u];
    xpc_object_t a = emptyDict();
    xpc_dictionary_set_uuid(a, "kCBMsgArgDeviceUUID", u);
    return a;
}

@implementation L2CAPChannel
- (instancetype)initWithFd:(int)fd cid:(uint16_t)cid mtu:(uint16_t)mtu {
    if ((self = [super init])) {
        _fd = fd;
        _cid = cid;
        _outMTU = mtu;
        // A write after bluetoothd closes its end must fail with EPIPE, not kill us.
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    }
    return self;
}
- (void)dealloc {
    if (_fd >= 0) close(_fd);
}
@end

@interface ClassicSession ()
@property(atomic, readwrite) BOOL invalidated;
@end

@implementation ClassicSession {
    xpc_connection_t _conn;
    dispatch_queue_t _queue;
    dispatch_semaphore_t _poweredOn;
    dispatch_semaphore_t _channelEvent;
    dispatch_semaphore_t _peerConnected;
    dispatch_semaphore_t _peerDisconnected;
    // Accessed only on _queue.
    uuid_t _watched; // device whose peer/channel events we act on
    BOOL _watching;
    int64_t _openResult; // last channel-opened event (one open is in flight at a time)
    int64_t _openCID;
    int64_t _openMTU;
    int _openFd;
}

- (instancetype)initWithName:(NSString *)name error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("btbridge.classic", NULL);
    _poweredOn = dispatch_semaphore_create(0);
    _channelEvent = dispatch_semaphore_create(0);
    _peerConnected = dispatch_semaphore_create(0);
    _peerDisconnected = dispatch_semaphore_create(0);
    _openFd = -1;

    _conn = xpc_connection_create_mach_service("com.apple.server.bluetooth.classic.xpc", _queue, 0);
    if (!_conn) {
        if (error) *error = makeError(@"couldn't reach bluetoothd");
        return nil;
    }
    __weak ClassicSession *weakSelf = self;
    xpc_connection_set_event_handler(_conn, ^(xpc_object_t ev) {
        [weakSelf handleEvent:ev];
    });
    xpc_connection_resume(_conn);

    // Lucid also claims kCBMsgArgIsPrivilegedDaemon here; bluetoothd serves everything
    // this needs without it, so we don't.
    xpc_object_t args = emptyDict();
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", emptyDict());
    xpc_dictionary_set_int64(args, "kCBMsgArgVersion", 20161219);
    xpc_dictionary_set_int64(args, "kCBMsgArgType", 3);
    xpc_dictionary_set_string(args, "kCBMsgArgName", name.UTF8String ?: "btbridge");
    [self send:kMsgCheckIn args:args];
    [self send:kMsgPairingAgentRegister args:emptyDict()];
    [self sendSync:kMsgRetrievePairedDevices args:nil];

    if (![self wait:_poweredOn seconds:5]) {
        if (error)
            *error = self.invalidated ? makeError(@"bluetoothd closed the connection")
                                      : makeError(@"Bluetooth is off (the controller isn't powered on)");
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_conn) xpc_connection_cancel(_conn);
    if (_openFd >= 0) close(_openFd);
}

#pragma mark - Transport

- (xpc_object_t)message:(int64_t)msgId args:(xpc_object_t)args {
    xpc_object_t m = emptyDict();
    xpc_dictionary_set_int64(m, "kCBMsgId", msgId);
    if (args) xpc_dictionary_set_value(m, "kCBMsgArgs", args);
    return m;
}

- (void)send:(int64_t)msgId args:(xpc_object_t)args {
    xpc_connection_send_message(_conn, [self message:msgId args:args]);
}

- (xpc_object_t)sendSync:(int64_t)msgId args:(xpc_object_t)args {
    return xpc_connection_send_message_with_reply_sync(_conn, [self message:msgId args:args]);
}

// Waits for s; returns NO on timeout or if the session became invalid meanwhile.
- (BOOL)wait:(dispatch_semaphore_t)s seconds:(double)seconds {
    if (self.invalidated) return NO;
    long r = dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
    return r == 0 && !self.invalidated;
}

- (void)drain:(dispatch_semaphore_t)s {
    while (dispatch_semaphore_wait(s, DISPATCH_TIME_NOW) == 0) {
    }
}

- (void)watch:(NSUUID *)device {
    dispatch_sync(_queue, ^{
        [device getUUIDBytes:self->_watched];
        self->_watching = YES;
    });
}

#pragma mark - Events (on _queue)

- (BOOL)isWatchedDevice:(xpc_object_t)args {
    const uint8_t *u = xpc_dictionary_get_uuid(args, "kCBMsgArgDeviceUUID");
    return _watching && u && memcmp(u, _watched, sizeof(uuid_t)) == 0;
}

- (void)handleEvent:(xpc_object_t)ev {
    if (xpc_get_type(ev) == XPC_TYPE_ERROR) {
        // Interrupted (bluetoothd restarted) or invalid: either way our check-in and
        // every channel are gone. Wake all waiters so nothing sits out its timeout.
        if (self.invalidated) return;
        self.invalidated = YES;
        for (dispatch_semaphore_t s in @[ _poweredOn, _channelEvent, _peerConnected, _peerDisconnected ])
            dispatch_semaphore_signal(s);
        void (^cb)(void) = self.onInvalidated;
        if (cb) cb();
        return;
    }
    if (xpc_get_type(ev) != XPC_TYPE_DICTIONARY) return;
    xpc_object_t args = xpc_dictionary_get_value(ev, "kCBMsgArgs");
    if (!args || xpc_get_type(args) != XPC_TYPE_DICTIONARY) return;

    switch (xpc_dictionary_get_int64(ev, "kCBMsgId")) {
    case kEvtStateUpdated:
        if (xpc_dictionary_get_int64(args, "kCBMsgArgState") == kStatePoweredOn) dispatch_semaphore_signal(_poweredOn);
        break;
    case kEvtChannelOpened: {
        if (![self isWatchedDevice:args]) break;
        if (_openFd >= 0) close(_openFd);
        _openFd = -1;
        _openResult = xpc_dictionary_get_int64(args, "kCBMsgArgResult");
        _openCID = xpc_dictionary_get_int64(args, "kCBMsgArgCID");
        _openMTU = xpc_dictionary_get_int64(args, "kCBMsgArgOutMTU");
        xpc_object_t s = xpc_dictionary_get_value(args, "kCBMsgArgSocket");
        if (_openResult == 0 && s && xpc_get_type(s) == XPC_TYPE_FD)
            _openFd = xpc_dictionary_dup_fd(args, "kCBMsgArgSocket");
        dispatch_semaphore_signal(_channelEvent);
        break;
    }
    case kEvtChannelClosed: {
        if (![self isWatchedDevice:args]) break;
        void (^cb)(uint16_t) = self.channelClosed;
        if (cb) cb((uint16_t)xpc_dictionary_get_int64(args, "kCBMsgArgPSM"));
        break;
    }
    case kEvtPeerConnected:
        if ([self isWatchedDevice:args] && xpc_dictionary_get_int64(args, "kCBMsgArgResult") == 0)
            dispatch_semaphore_signal(_peerConnected);
        break;
    case kEvtPeerDisconnected:
        if ([self isWatchedDevice:args]) dispatch_semaphore_signal(_peerDisconnected);
        break;
    }
}

#pragma mark - Devices

- (NSUUID *)lookupAddress:(NSString *)address connected:(BOOL *)connected error:(NSError **)error {
    if (self.invalidated) {
        if (error) *error = makeError(@"bluetoothd closed the connection");
        return nil;
    }
    // bluetoothd only matches "aa:bb:cc:dd:ee:ff"; IOBluetooth hands out "aa-bb-cc-dd-ee-ff".
    NSString *canonical = [address.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
    xpc_object_t args = emptyDict();
    xpc_dictionary_set_string(args, "kCBMsgArgAddressString", canonical.UTF8String);
    xpc_object_t reply = [self sendSync:kMsgRetrievePeerWithAddress args:args];
    xpc_object_t dev = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(reply, "kCBMsgArgDevices") : NULL;
    if (!dev || xpc_get_type(dev) != XPC_TYPE_DICTIONARY) {
        if (error) *error = makeError(@"bluetoothd doesn't know %@", address);
        return nil;
    }
    const uint8_t *u = xpc_dictionary_get_uuid(dev, "kCBMsgArgDeviceUUID");
    // bluetoothd creates a record for any address it's asked about, so check pairing.
    if (!u || xpc_dictionary_get_int64(dev, "kCBMsgArgPairingState") != kPairingStatePaired) {
        if (error) *error = makeError(@"%@ is not paired with this Mac", address);
        return nil;
    }
    if (connected) *connected = xpc_dictionary_get_int64(dev, "kCBMsgArgInternalState") == kInternalStateConnected;
    return [[NSUUID alloc] initWithUUIDBytes:u];
}

- (void)forceDisconnect:(NSUUID *)device {
    xpc_object_t args = peerArgs(device);
    xpc_object_t opts = emptyDict();
    xpc_dictionary_set_int64(opts, "kCBCancelConnectOptionForce", 1);
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", opts);
    [self send:kMsgCancelPeerConnection args:args];
}

- (void)connect:(NSUUID *)device {
    // Without resetting the history, bluetoothd refuses (result 3) to reconnect a
    // device that was force-disconnected moments ago.
    xpc_object_t args = peerArgs(device);
    xpc_object_t opts = emptyDict();
    xpc_dictionary_set_int64(opts, "kCBConnectOptionConnectionOptionResetDisconnectionHistory", 1);
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", opts);
    [self send:kMsgConnectPeer args:args];
}

#pragma mark - Channels

- (BOOL)requestChannel:(NSUUID *)device psm:(uint16_t)psm timeout:(double)timeout {
    [self drain:_channelEvent];
    xpc_object_t args = peerArgs(device);
    xpc_dictionary_set_int64(args, "kCBMsgArgPSM", psm);
    xpc_dictionary_set_value(args, "kCBMsgArgOptions", emptyDict());
    [self send:kMsgOpenChannel args:args];
    return [self wait:_channelEvent seconds:timeout];
}

- (int64_t)lastOpenResult {
    __block int64_t result;
    dispatch_sync(_queue, ^{
        result = self->_openResult;
    });
    return result;
}

- (L2CAPChannel *)takeChannelOrError:(NSError **)error {
    __block L2CAPChannel *ch = nil;
    __block int64_t result;
    dispatch_sync(_queue, ^{
        result = self->_openResult;
        if (result == 0 && self->_openFd >= 0) {
            ch = [[L2CAPChannel alloc] initWithFd:self->_openFd cid:(uint16_t)self->_openCID mtu:(uint16_t)self->_openMTU];
            self->_openFd = -1;
        }
    });
    if (!ch && error)
        *error = result == 0 ? makeError(@"bluetoothd opened the channel but sent no socket")
                             : makeError(@"L2CAP open failed (bluetoothd result %lld)", result);
    return ch;
}

- (L2CAPChannel *)openChannelTo:(NSUUID *)device psm:(uint16_t)psm error:(NSError **)error {
    [self watch:device];
    if (![self requestChannel:device psm:psm timeout:15]) {
        if (error)
            *error = self.invalidated ? makeError(@"bluetoothd closed the connection")
                                      : makeError(@"no answer to L2CAP open on PSM 0x%x", psm);
        return nil;
    }
    return [self takeChannelOrError:error];
}

- (L2CAPChannel *)takeOverAVDTP:(NSUUID *)device error:(NSError **)error {
    [self watch:device];
    [self drain:_peerDisconnected];
    [self forceDisconnect:device];
    // No event arrives if the device was already disconnected; the timeout covers that.
    [self wait:_peerDisconnected seconds:5];
    usleep(500 * 1000);

    [self connect:device];
    // Poll until the ACL exists. Each attempt fails immediately with kResultNoLink
    // until then, and the first one after the link is up wins PSM 25.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kTakeOverWindowSeconds];
    BOOL answered = NO;
    while (!self.invalidated && deadline.timeIntervalSinceNow > 0) {
        if (![self requestChannel:device psm:kPSMAVDTP timeout:3]) continue;
        if ([self lastOpenResult] != kResultNoLink) {
            answered = YES;
            break;
        }
        usleep(15 * 1000);
    }
    if (!answered) {
        if (error)
            *error = self.invalidated ? makeError(@"bluetoothd closed the connection")
                                      : makeError(@"the headphones didn't reconnect (are they on and in range?)");
        return nil;
    }
    return [self takeChannelOrError:error];
}

- (void)closeChannelTo:(NSUUID *)device psm:(uint16_t)psm {
    xpc_object_t args = peerArgs(device);
    xpc_dictionary_set_int64(args, "kCBMsgArgPSM", psm);
    [self send:kMsgCloseChannel args:args];
}

- (BOOL)handBack:(NSUUID *)device {
    [self watch:device];
    [self drain:_peerDisconnected];
    [self forceDisconnect:device];
    [self wait:_peerDisconnected seconds:5];
    usleep(500 * 1000);
    [self drain:_peerConnected];
    [self connect:device];
    return [self wait:_peerConnected seconds:10];
}

@end
