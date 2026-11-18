// SPDX-License-Identifier: GPL-3.0-only
#import "BridgeEngine.h"

#include <mach/mach_time.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <unistd.h>

#import <IOBluetooth/IOBluetooth.h>

#import "A2DPLink.h"
#import "AudioDevices.h"
#import "ClassicSession.h"
#import "SystemAudioTap.h"
#include "ldac_rtp.h"
#include "pcm_ring.h"

static NSString *const kQualityNames[] = {@"HQ 990 kbps", @"SQ 660 kbps", @"MQ 330 kbps"};

// Written before the engine changes anything and cleared after a clean teardown. If
// it's still there at launch, the last run crashed or was killed mid-stream.
static NSString *const kRecoveryKey = @"pendingRecovery";

// Audio queued beyond this is skipped so latency can't grow without bound.
static const double kMaxQueuedSeconds = 0.25;
// Captured audio plays this far behind capture, absorbing callback jitter.
static const double kJitterSeconds = 0.030;
// If sending stalls for longer than this, resume from "now" instead of bursting.
static const double kMaxCatchUpSeconds = 0.050;

static NSError *engineError(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static NSError *engineError(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:@"BridgeEngine" code:1 userInfo:@{NSLocalizedDescriptionKey : msg}];
}

static BOOL isBluetoothAddress(NSString *address) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$" options:0 error:NULL];
    });
    return address && [re numberOfMatchesInString:address options:0 range:NSMakeRange(0, address.length)] == 1;
}

@interface BridgeEngine ()
@property(atomic, readwrite) BridgeState state;
@end

@implementation BridgeEngine {
    dispatch_queue_t _work;
    ClassicSession *_session;
    NSUUID *_device;
    L2CAPChannel *_signaling;
    A2DPLink *_link;
    SystemAudioTap *_muteTap; // silences the speakers while the headphones change hands
    SystemAudioTap *_tap;     // the capture tap, created once the speakers are the output
    ldac_rtp *_encoder;
    pcm_ring _ring;
    pthread_t _encoderThread;
    BOOL _encoderRunning;
    atomic_bool _stopEncoder;
    int _rate;
    int _quality;
    double _originalBuiltInRate; // restored on teardown
    NSString *_address;

    // Statistics (written by the encoder thread, read for display).
    _Atomic uint64_t _packets;
    _Atomic uint64_t _bytes;
    _Atomic uint64_t _skipped;
    _Atomic uint64_t _underruns;
    _Atomic uint32_t _peakBits; // float bit pattern of the peak sample since last read
    NSDate *_started;
    // Per-interval counters, reset by -statistics.
    _Atomic uint64_t _callbacks;
    _Atomic uint64_t _capturedFrames;
    _Atomic uint64_t _maxCallbackGapUs;
    _Atomic uint64_t _maxWriteUs;
    _Atomic uint64_t _lastCallbackTicks;
    uint64_t _lastPackets;
    NSDate *_lastStats;
}

- (instancetype)init {
    if ((self = [super init])) {
        _work = dispatch_queue_create("btbridge.engine", NULL);
    }
    return self;
}

// Runs on _work.
- (void)report:(BridgeState)state message:(NSString *)message {
    self.state = state;
    NSLog(@"btbridge: %@", message);
    void (^cb)(BridgeState, NSString *) = self.onStateChange;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{
        cb(state, message);
    });
}

#pragma mark - Start

- (void)startWithAddress:(NSString *)address quality:(int)quality sampleRate:(int)sampleRate {
    dispatch_async(_work, ^{
        if (self.state != BridgeStateIdle) {
            NSLog(@"btbridge: start ignored, engine is busy (state %ld)", (long)self.state);
            return;
        }
        if (!isBluetoothAddress(address)) {
            [self report:BridgeStateIdle message:[NSString stringWithFormat:@"Failed: \"%@\" isn't a Bluetooth address", address]];
            return;
        }
        self->_quality = quality < 0 || quality > 2 ? 0 : quality;
        self->_rate = sampleRate;
        [self report:BridgeStateConnecting message:@"Connecting…"];
        NSError *err;
        if (![self bringUp:address error:&err]) {
            NSString *why = err.localizedDescription ?: @"unknown error";
            [self tearDown];
            [self report:BridgeStateIdle message:[@"Failed: " stringByAppendingString:why]];
            return;
        }
        [self report:BridgeStateStreaming
             message:[NSString stringWithFormat:@"Streaming LDAC %.1f kHz · %@", self->_rate / 1000.0,
                                                kQualityNames[self->_quality]]];
    });
}

- (BOOL)bringUp:(NSString *)address error:(NSError **)error {
    // Mute first: once the headphones lose A2DP, macOS falls back to the speakers.
    _muteTap = [[SystemAudioTap alloc] initWithError:error];
    if (!_muteTap) return NO;

    // Capture is clocked by the built-in output (see below), so run it at the rate
    // LDAC will use; LDAC can then be negotiated the moment the headphones are ours.
    AudioDeviceID builtIn = [AudioDevices builtInOutput];
    if (builtIn == kAudioObjectUnknown) {
        if (error) *error = engineError(@"this Mac has no built-in audio output to clock the capture from");
        return NO;
    }
    _originalBuiltInRate = [AudioDevices nominalRateOf:builtIn];
    _address = address;
    [NSUserDefaults.standardUserDefaults setObject:@{@"address" : address, @"builtInRate" : @(_originalBuiltInRate)}
                                            forKey:kRecoveryKey];
    if ((_rate != 44100 && _rate != 48000 && _rate != 88200 && _rate != 96000) ||
        ![AudioDevices setNominalRate:_rate of:builtIn]) {
        if (error) *error = engineError(@"the Mac's built-in output can't run at %d Hz", _rate);
        return NO;
    }

    _session = [[ClassicSession alloc] initWithName:@"btbridge" error:error];
    if (!_session) return NO;
    _device = [_session lookupAddress:address connected:NULL error:error];
    if (!_device) return NO;
    _signaling = [_session takeOverAVDTP:_device error:error];
    if (!_signaling) {
        // macOS occasionally reclaims the link first; one more attempt usually wins.
        NSLog(@"btbridge: take-over failed (%@), retrying once", (error && *error) ? (*error).localizedDescription : @"?");
        usleep(1000 * 1000);
        _signaling = [_session takeOverAVDTP:_device error:error];
    }
    if (!_signaling) return NO;
    __weak BridgeEngine *weakSelf = self;
    _session.channelClosed = ^(uint16_t psm) {
        if (psm == kPSMAVDTP) [weakSelf lostLink:@"Bluetooth link lost"];
    };
    _session.onInvalidated = ^{
        [weakSelf lostLink:@"bluetoothd restarted"];
    };

    // Negotiate before anything else can stall: the headphones expect a prompt answer
    // on a freshly opened signaling channel.
    _link = [[A2DPLink alloc] initWithDevice:_device signaling:_signaling];
    if (![_link startLDACAtRate:_rate error:error]) return NO;
    _encoder = ldac_rtp_create(_rate, _quality, _link.mediaMTU);
    if (!_encoder) {
        if (error) *error = engineError(@"the LDAC encoder couldn't be set up (%d Hz, MTU %u)", _rate, _link.mediaMTU);
        return NO;
    }

    // Clock the capture from the built-in output so a hands-free (HFP) device the
    // headphones might still expose can never become the default route.
    if (builtIn != kAudioObjectUnknown && [AudioDevices defaultOutput] != builtIn) [AudioDevices setDefaultOutput:builtIn];

    // A tap takes its format from the default output at creation time, so create the
    // capture tap only now that the speakers (at _rate) are the default.
    _tap = [[SystemAudioTap alloc] initWithError:error];
    if (!_tap) return NO;
    [_muteTap stop];
    _muteTap = nil;

    pcm_ring_free(&_ring);
    if (!pcm_ring_init(&_ring, 1 << 16)) {
        if (error) *error = engineError(@"out of memory for the audio buffer");
        return NO;
    }
    pcm_ring *ring = &_ring;
    _Atomic uint64_t *callbacks = &_callbacks, *captured = &_capturedFrames, *maxGap = &_maxCallbackGapUs,
                     *lastTicks = &_lastCallbackTicks;
    if (![_tap startWithHandler:^(const float *frames, uint32_t count) {
            uint64_t now = mach_absolute_time(), prev = atomic_exchange(lastTicks, now);
            if (prev) atomicMax(maxGap, ticksToUs(now - prev));
            atomic_fetch_add(callbacks, 1);
            atomic_fetch_add(captured, count);
            pcm_ring_write(ring, frames, count);
        }
                          error:error])
        return NO;

    if (lround(_tap.sampleRate) != _rate) {
        if (error) *error = engineError(@"capture runs at %.0f Hz, expected %d", _tap.sampleRate, _rate);
        return NO;
    }
    if (![self startEncoder]) {
        if (error) *error = engineError(@"couldn't start the encoder thread");
        return NO;
    }
    return YES;
}

#pragma mark - Encoder thread

static uint64_t ticksToUs(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info(&tb);
    });
    return ticks * tb.numer / tb.denom / 1000;
}

static void atomicMax(_Atomic uint64_t *slot, uint64_t v) {
    uint64_t old = atomic_load(slot);
    while (v > old && !atomic_compare_exchange_weak(slot, &old, v)) {
    }
}

static void *encoderMain(void *arg) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    [(__bridge BridgeEngine *)arg encodeLoop];
    return NULL;
}

- (BOOL)startEncoder {
    atomic_store(&_packets, 0);
    atomic_store(&_bytes, 0);
    atomic_store(&_skipped, 0);
    atomic_store(&_underruns, 0);
    _started = [NSDate date];
    // Start from live audio, not whatever queued up during negotiation.
    pcm_ring_skip(&_ring, pcm_ring_available(&_ring));
    atomic_store(&_stopEncoder, false);
    _encoderRunning = pthread_create(&_encoderThread, NULL, encoderMain, (__bridge void *)self) == 0;
    return _encoderRunning;
}

- (void)stopEncoder {
    if (!_encoderRunning) return;
    atomic_store(&_stopEncoder, true);
    pthread_join(_encoderThread, NULL);
    _encoderRunning = NO;
}

// Returns 1 when sent, 0 if asked to stop while waiting, -1 on error.
- (int)sendPacket:(const uint8_t *)pkt length:(int)n fd:(int)fd {
    for (;;) {
        ssize_t w = write(fd, pkt, (size_t)n);
        if (w == n) return 1;
        if (w >= 0 || errno != EAGAIN) return -1;
        struct pollfd p = {fd, POLLOUT, 0};
        while (poll(&p, 1, 100) == 0) {
            if (atomic_load(&_stopEncoder)) return 0;
        }
    }
}

// The encoder runs on its own real-time clock rather than on capture callbacks:
//  - packets go out evenly (one every ~5 ms). The media channel is a byte stream that
//    bluetoothd re-cuts into L2CAP packets as it reads, so two RTP packets written
//    back to back can get merged and split at the MTU, corrupting both;
//  - the tap only delivers audio while something is playing, and the headphones
//    need a continuous stream, so gaps are filled with silence.
// Captured audio is played kJitterSeconds behind capture to absorb callback jitter.
- (void)encodeLoop {
    float pcm[LDAC_RTP_FRAMES * 2];
    uint8_t pkt[LDAC_RTP_MAX_PACKET];
    int fd = _link.mediaFd;
    if (fd < 0 || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) {
        [self encoderFailed:@"the audio channel isn't usable"];
        return;
    }
    const uint32_t jitter = (uint32_t)(kJitterSeconds * _rate);
    const uint32_t maxQueued = (uint32_t)(kMaxQueuedSeconds * _rate);
    const uint64_t maxBehind = (uint64_t)(kMaxCatchUpSeconds * _rate);
    const uint64_t start = mach_absolute_time();
    uint64_t consumed = 0;
    BOOL priming = YES; // waiting for the jitter buffer to fill before playing capture

    while (!atomic_load(&_stopEncoder) && !_link.interrupted) {
        uint64_t due = ticksToUs(mach_absolute_time() - start) * (uint64_t)_rate / 1000000;
        if (due > consumed + maxBehind) consumed = due - LDAC_RTP_FRAMES; // stalled: don't burst to catch up
        while (!atomic_load(&_stopEncoder) && consumed + LDAC_RTP_FRAMES <= due) {
            uint32_t queued = pcm_ring_available(&_ring);
            if (queued > maxQueued) {
                pcm_ring_skip(&_ring, queued - jitter);
                atomic_fetch_add(&_skipped, queued - jitter);
                queued = jitter;
            }
            if (priming && queued >= jitter) priming = NO;
            if (!priming && pcm_ring_read(&_ring, pcm, LDAC_RTP_FRAMES)) {
                float peak = 0;
                for (int i = 0; i < LDAC_RTP_FRAMES * 2; i++) peak = fmaxf(peak, fabsf(pcm[i]));
                uint32_t bits;
                memcpy(&bits, &peak, sizeof bits);
                uint32_t old = atomic_load(&_peakBits);
                while (bits > old && !atomic_compare_exchange_weak(&_peakBits, &old, bits)) {
                }
            } else {
                memset(pcm, 0, sizeof pcm);
                if (!priming) {
                    priming = YES;
                    atomic_fetch_add(&_underruns, 1);
                }
            }
            consumed += LDAC_RTP_FRAMES;

            int n = ldac_rtp_encode(_encoder, pcm, pkt);
            if (n < 0) {
                [self encoderFailed:@"LDAC encoder error"];
                return;
            }
            if (n == 0) continue;
            uint64_t t0 = mach_absolute_time();
            int sent = [self sendPacket:pkt length:n fd:fd];
            if (sent == 0) break;
            if (sent < 0) {
                [self encoderFailed:@"headphones stopped accepting audio"];
                return;
            }
            atomicMax(&_maxWriteUs, ticksToUs(mach_absolute_time() - t0));
            atomic_fetch_add(&_packets, 1);
            atomic_fetch_add(&_bytes, (uint64_t)n);
        }
        usleep(1000);
    }
    if (_link.interrupted && !atomic_load(&_stopEncoder)) [self encoderFailed:@"headphones ended the stream"];
}

// Both may be called from any thread; the state check makes repeats harmless.
- (void)encoderFailed:(NSString *)why {
    dispatch_async(_work, ^{
        if (self.state != BridgeStateStreaming) return;
        [self shutDownWithMessage:[@"Stopped: " stringByAppendingString:why]];
    });
}

- (void)lostLink:(NSString *)why {
    [self encoderFailed:why];
}

#pragma mark - Stop

- (void)stop {
    dispatch_async(_work, ^{
        if (self.state != BridgeStateStreaming) return;
        [self shutDownWithMessage:@"Idle"];
    });
}

- (void)stopAndWait {
    [self stop];
    dispatch_sync(_work, ^{
    });
}

// Runs on _work.
- (void)shutDownWithMessage:(NSString *)message {
    [self report:BridgeStateStopping message:@"Returning headphones to macOS…"];
    [self tearDown];
    [self report:BridgeStateIdle message:message];
}

- (void)tearDown {
    [self stopEncoder];
    [_link stop];
    _link = nil;
    ldac_rtp_free(_encoder);
    _encoder = NULL;
    if (_device) {
        _session.channelClosed = nil;
        _session.onInvalidated = nil;
        [_session closeChannelTo:_device psm:kPSMAVDTP];
        _signaling = nil;
        [self returnHeadphones];
    }
    // Unmute only now, so audio doesn't play from the speakers in the gap.
    [_tap stop];
    _tap = nil;
    [_muteTap stop];
    _muteTap = nil;
    if (_originalBuiltInRate > 0) [AudioDevices setNominalRate:_originalBuiltInRate of:[AudioDevices builtInOutput]];
    _originalBuiltInRate = 0;
    _session = nil;
    _device = nil;
    _address = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kRecoveryKey];
}

// Hands the headphones back to macOS. If bluetoothd's reconnect doesn't bring them
// back as an audio output, falls back to the public IOBluetooth reconnect.
- (void)returnHeadphones {
    // A dead session (bluetoothd restarted) can't hand back; go straight to IOBluetooth.
    BOOL reconnected = !_session.invalidated && [_session handBack:_device];
    if (reconnected && [self waitForHeadphonesAsOutput:5]) return;
    NSLog(@"btbridge: headphones didn't come back on their own; reconnecting via IOBluetooth");
    [BridgeEngine reconnectWithIOBluetooth:_address];
    [self waitForHeadphonesAsOutput:5];
}

+ (void)reconnectWithIOBluetooth:(NSString *)address {
    // IOBluetooth wants "aa-bb-cc-dd-ee-ff".
    NSString *dashed = [address stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:dashed];
    if (!d) return;
    if (d.isConnected) {
        [d closeConnection];
        usleep(1000 * 1000);
    }
    [d openConnection];
}

- (void)recoverFromPreviousRun {
    dispatch_async(_work, ^{
        NSDictionary *pending = [NSUserDefaults.standardUserDefaults dictionaryForKey:kRecoveryKey];
        NSString *address = pending[@"address"];
        if (!pending) return;
        if (![address isKindOfClass:NSString.class] || !isBluetoothAddress(address)) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kRecoveryKey];
            return;
        }
        [self report:BridgeStateStopping message:@"Restoring headphones after an unclean exit…"];
        double rate = [pending[@"builtInRate"] doubleValue];
        if (rate > 0) [AudioDevices setNominalRate:rate of:[AudioDevices builtInOutput]];
        self->_session = [[ClassicSession alloc] initWithName:@"btbridge" error:NULL];
        self->_device = [self->_session lookupAddress:address connected:NULL error:NULL];
        self->_address = address;
        if (self->_device) [self returnHeadphones];
        else [BridgeEngine reconnectWithIOBluetooth:address];
        self->_session = nil;
        self->_device = nil;
        self->_address = nil;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kRecoveryKey];
        [self report:BridgeStateIdle message:@"Idle"];
    });
}

// Waits for macOS to recreate the headphones' own audio output device.
- (BOOL)waitForHeadphonesAsOutput:(double)seconds {
    if (!_address) return NO;
    for (double t = 0; t < seconds; t += 0.1) {
        if ([AudioDevices outputForBluetoothAddress:_address] != kAudioObjectUnknown) return YES;
        usleep(100 * 1000);
    }
    return NO;
}

#pragma mark - Diagnostics

- (NSString *)statistics {
    double secs = _started ? -_started.timeIntervalSinceNow : 0;
    double interval = _lastStats ? -_lastStats.timeIntervalSinceNow : secs;
    _lastStats = [NSDate date];
    uint32_t bits = atomic_exchange(&_peakBits, 0);
    float peak;
    memcpy(&peak, &bits, sizeof peak);
    double db = peak > 0 ? 20 * log10(peak) : -INFINITY;
    uint64_t packets = atomic_load(&_packets);
    uint64_t intervalPackets = packets - _lastPackets;
    _lastPackets = packets;
    double rate = interval > 0 ? 1 / interval : 0;
    return [NSString stringWithFormat:@"pkt/s=%.0f cap=%.0f fr/s cb/s=%.0f maxGap=%llums maxWrite=%llums "
                                      @"peak=%.1fdBFS total=%llu skipped=%llu underruns=%llu dropped=%llu",
                                      intervalPackets * rate, atomic_exchange(&_capturedFrames, 0) * rate,
                                      atomic_exchange(&_callbacks, 0) * rate, atomic_exchange(&_maxCallbackGapUs, 0) / 1000,
                                      atomic_exchange(&_maxWriteUs, 0) / 1000, db, packets, atomic_load(&_skipped),
                                      atomic_load(&_underruns), atomic_load(&_ring.dropped)];
}

- (void)dealloc {
    pcm_ring_free(&_ring);
}

@end
