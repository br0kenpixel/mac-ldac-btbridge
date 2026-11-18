// SPDX-License-Identifier: GPL-3.0-only
#import "A2DPLink.h"

#include <pthread.h>
#include <stdatomic.h>

#include "avdtp.h"
#include "ldac_rtp.h"

static const uint8_t kLocalSEID = 1;

// AVDTP error codes used when rejecting the sink's commands.
static const uint8_t kErrBadACPSEID = 0x12;
static const uint8_t kErrSEPInUse = 0x13;

static NSError *linkError(NSString *msg) {
    return [NSError errorWithDomain:@"A2DPLink" code:1 userInfo:@{NSLocalizedDescriptionKey : msg}];
}

// Our source endpoint's capabilities: media transport + LDAC, all four rates, stereo.
static size_t localCapabilities(uint8_t *out) {
    static const uint8_t caps[] = {AVDTP_CAT_MEDIA_TRANSPORT, 0, AVDTP_CAT_MEDIA_CODEC, 10, 0x00, A2DP_CODEC_VENDOR,
                                   0x2d, 0x01, 0x00, 0x00, 0xaa, 0x00, 0x3c, 0x01};
    memcpy(out, caps, sizeof caps);
    return sizeof caps;
}

@interface A2DPLink ()
@property(atomic, readwrite) BOOL interrupted;
- (uint8_t)answer:(const avdtp_msg *)cmd resp:(uint8_t *)resp len:(size_t *)len;
@end

static uint8_t handleCommand(void *ctx, const avdtp_msg *cmd, uint8_t *resp, size_t *resp_len) {
    return [(__bridge A2DPLink *)ctx answer:cmd resp:resp len:resp_len];
}

@implementation A2DPLink {
    ClassicSession *_mediaSession;
    NSUUID *_device;
    L2CAPChannel *_signaling;
    L2CAPChannel *_media;
    avdtp_signaling _av;
    uint8_t _remoteSEID;
    BOOL _streaming;
    int _lastType;
    uint8_t _lastError;
    pthread_t _serviceThread;
    BOOL _serviceRunning;
    atomic_bool _stopService;
}

- (instancetype)initWithDevice:(NSUUID *)device signaling:(L2CAPChannel *)signaling {
    if ((self = [super init])) {
        _device = device;
        _signaling = signaling;
        _av.fd = signaling.fd;
        _av.on_command = handleCommand;
        _av.ctx = (__bridge void *)self;
        _av.trace = getenv("AVDTP_TRACE") != NULL;
    }
    return self;
}

- (int)mediaFd {
    return _media ? _media.fd : -1;
}

- (uint16_t)mediaMTU {
    return _media.outMTU;
}

#pragma mark - Sink-initiated commands

- (uint8_t)answer:(const avdtp_msg *)cmd resp:(uint8_t *)resp len:(size_t *)len {
    uint8_t seid = cmd->len ? cmd->payload[0] >> 2 : 0;
    *len = 0;
    switch (cmd->signal) {
    case AVDTP_DISCOVER:
        resp[0] = (uint8_t)(kLocalSEID << 2 | (_remoteSEID ? 0x02 : 0)); // in use once configured
        resp[1] = 0x00;                                                   // audio, source
        *len = 2;
        return AVDTP_MSG_ACCEPT;
    case AVDTP_GET_CAPABILITIES:
    case AVDTP_GET_ALL_CAPABILITIES:
        if (seid != kLocalSEID) {
            resp[0] = kErrBadACPSEID;
            *len = 1;
            return AVDTP_MSG_REJECT;
        }
        *len = localCapabilities(resp);
        return AVDTP_MSG_ACCEPT;
    case AVDTP_SET_CONFIGURATION:
        resp[0] = 0;
        resp[1] = kErrSEPInUse;
        *len = 2;
        return AVDTP_MSG_REJECT;
    case AVDTP_DELAY_REPORT:
    case AVDTP_START:
        return AVDTP_MSG_ACCEPT;
    case AVDTP_SUSPEND:
    case AVDTP_CLOSE:
    case AVDTP_ABORT:
        self.interrupted = YES;
        return AVDTP_MSG_ACCEPT;
    default:
        return AVDTP_MSG_GENERAL_REJECT;
    }
}

#pragma mark - Stream setup

- (int)request:(uint8_t)signal payload:(const uint8_t *)payload len:(size_t)len {
    uint8_t resp[AVDTP_MAX_SIGNAL];
    size_t rlen = 0;
    int t = avdtp_request(&_av, signal, payload, len, resp, &rlen, 3000);
    _lastError = t == AVDTP_MSG_REJECT && rlen ? resp[rlen - 1] : 0;
    _lastType = t;
    return t;
}

// e.g. "rejected (error 0x31)" or "timed out", for error messages.
- (NSString *)lastOutcome {
    if (_lastType < 0) return @"no response";
    if (_lastType == AVDTP_MSG_REJECT) return [NSString stringWithFormat:@"rejected, error 0x%02x", _lastError];
    if (_lastType == AVDTP_MSG_GENERAL_REJECT) return @"general reject";
    return @"accepted";
}

// Finds the sink's LDAC endpoint and its capabilities. Returns its SEID, or 0 with
// *error set.
- (uint8_t)findLDACEndpoint:(a2dp_codec_caps *)caps error:(NSError **)error {
    uint8_t resp[AVDTP_MAX_SIGNAL];
    size_t rlen = 0;
    if (avdtp_request(&_av, AVDTP_DISCOVER, NULL, 0, resp, &rlen, 3000) != AVDTP_MSG_ACCEPT) {
        if (error) *error = linkError(@"the headphones didn't answer endpoint discovery");
        return 0;
    }
    avdtp_sep seps[16];
    size_t n = avdtp_parse_discover(resp, rlen, seps, 16);
    BOOL busy = NO;
    for (size_t i = 0; i < n; i++) {
        if (seps[i].media_type != 0 || !seps[i].is_sink) continue;
        uint8_t arg = (uint8_t)(seps[i].seid << 2);
        int t = avdtp_request(&_av, AVDTP_GET_ALL_CAPABILITIES, &arg, 1, resp, &rlen, 3000);
        if (t != AVDTP_MSG_ACCEPT) t = avdtp_request(&_av, AVDTP_GET_CAPABILITIES, &arg, 1, resp, &rlen, 3000);
        if (t != AVDTP_MSG_ACCEPT || !avdtp_parse_codec(resp, rlen, caps) || strcmp(a2dp_codec_name(caps), "LDAC"))
            continue;
        if (seps[i].in_use) {
            busy = YES;
            continue;
        }
        if (caps->info_len < 2) continue;
        return seps[i].seid;
    }
    if (error)
        *error = linkError(busy ? @"the headphones' LDAC endpoint is in use by another device"
                                : @"these headphones don't support LDAC");
    return 0;
}

- (BOOL)startLDACAtRate:(int)sampleRate error:(NSError **)error {
    a2dp_codec_caps caps;
    uint8_t seid = [self findLDACEndpoint:&caps error:error];
    if (!seid) return NO;
    uint8_t wanted[2];
    if (!ldac_rtp_config(sampleRate, wanted)) {
        if (error) *error = linkError([NSString stringWithFormat:@"LDAC has no %d Hz mode", sampleRate]);
        return NO;
    }
    if (!(caps.info[0] & wanted[0])) {
        if (error)
            *error = linkError([NSString stringWithFormat:@"these headphones don't support LDAC at %.1f kHz", sampleRate / 1000.0]);
        return NO;
    }
    if (!(caps.info[1] & wanted[1])) {
        if (error) *error = linkError(@"these headphones don't support stereo LDAC");
        return NO;
    }

    uint8_t cfg[32];
    size_t n = 0;
    cfg[n++] = (uint8_t)(seid << 2);
    cfg[n++] = (uint8_t)(kLocalSEID << 2);
    cfg[n++] = AVDTP_CAT_MEDIA_TRANSPORT;
    cfg[n++] = 0;
    cfg[n++] = AVDTP_CAT_MEDIA_CODEC;
    cfg[n++] = 10;
    cfg[n++] = 0x00; // audio
    cfg[n++] = A2DP_CODEC_VENDOR;
    const uint8_t ldacIds[] = {0x2d, 0x01, 0x00, 0x00, 0xaa, 0x00};
    memcpy(cfg + n, ldacIds, sizeof ldacIds);
    n += sizeof ldacIds;
    memcpy(cfg + n, wanted, sizeof wanted);
    n += sizeof wanted;
    if ([self request:AVDTP_SET_CONFIGURATION payload:cfg len:n] != AVDTP_MSG_ACCEPT) {
        if (error) *error = linkError([@"LDAC SET_CONFIGURATION: " stringByAppendingString:self.lastOutcome]);
        return NO;
    }
    _remoteSEID = seid;

    uint8_t acp = (uint8_t)(seid << 2);
    if ([self request:AVDTP_OPEN payload:&acp len:1] != AVDTP_MSG_ACCEPT) {
        if (error) *error = linkError([@"AVDTP OPEN: " stringByAppendingString:self.lastOutcome]);
        return NO;
    }

    // The media transport is a second L2CAP channel on the same PSM. A separate
    // session keeps its open/close bookkeeping apart from the signaling channel.
    _mediaSession = [[ClassicSession alloc] initWithName:@"btbridge.media" error:error];
    if (!_mediaSession) return NO;
    _media = [_mediaSession openChannelTo:_device psm:kPSMAVDTP error:error];
    if (!_media) return NO;
    if (_media.outMTU < LDAC_RTP_MIN_MTU) {
        if (error)
            *error = linkError([NSString stringWithFormat:@"the headphones' packet size (%u bytes) is too small for LDAC",
                                                          _media.outMTU]);
        return NO;
    }

    if ([self request:AVDTP_START payload:&acp len:1] != AVDTP_MSG_ACCEPT) {
        if (error) *error = linkError([@"AVDTP START: " stringByAppendingString:self.lastOutcome]);
        return NO;
    }
    _streaming = YES;
    [self startServiceThread];
    return YES;
}

#pragma mark - Signaling while streaming

static void *serviceLoop(void *arg) {
    A2DPLink *link = (__bridge A2DPLink *)arg;
    [link serviceUntilStopped];
    return NULL;
}

- (void)serviceUntilStopped {
    while (!atomic_load(&_stopService)) {
        if (!avdtp_service(&_av, 200)) {
            self.interrupted = YES;
            break;
        }
    }
}

- (void)startServiceThread {
    atomic_store(&_stopService, false);
    _serviceRunning = pthread_create(&_serviceThread, NULL, serviceLoop, (__bridge void *)self) == 0;
}

- (void)stopServiceThread {
    if (!_serviceRunning) return;
    atomic_store(&_stopService, true);
    pthread_join(_serviceThread, NULL);
    _serviceRunning = NO;
}

- (void)stop {
    [self stopServiceThread];
    if (_remoteSEID && !self.interrupted) {
        uint8_t acp = (uint8_t)(_remoteSEID << 2);
        if (_streaming) [self request:AVDTP_SUSPEND payload:&acp len:1];
        [self request:AVDTP_CLOSE payload:&acp len:1];
    }
    _streaming = NO;
    _remoteSEID = 0;
    if (_media) [_mediaSession closeChannelTo:_device psm:kPSMAVDTP];
    _media = nil;
    _mediaSession = nil;
}

- (void)dealloc {
    [self stopServiceThread];
}

@end
