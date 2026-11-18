// SPDX-License-Identifier: GPL-3.0-only
// caps: take over the headphones' AVDTP channel, list every sink endpoint's codec
// capabilities, then hand the headphones back to macOS.
//
//   caps <aa:bb:cc:dd:ee:ff>
//
// Set AVDTP_TRACE=1 to print the raw signaling.

#import <Foundation/Foundation.h>

#import "ClassicSession.h"
#include "avdtp.h"

static void printCodec(uint8_t seid, const a2dp_codec_caps *c) {
    printf("  SEID %u: %-7s", seid, a2dp_codec_name(c));
    if (c->codec_type == A2DP_CODEC_VENDOR) printf(" vendor=0x%08x codec=0x%04x", c->vendor_id, c->vendor_codec_id);
    printf(" info=");
    for (size_t i = 0; i < c->info_len; i++) printf("%02x", c->info[i]);
    if (c->delay_reporting) printf(" delay-reporting");
    printf("\n");
}

static void listCodecs(int fd) {
    avdtp_signaling av = {.fd = fd, .trace = getenv("AVDTP_TRACE") != NULL};
    uint8_t resp[AVDTP_MAX_SIGNAL];
    size_t rlen = 0;
    if (avdtp_request(&av, AVDTP_DISCOVER, NULL, 0, resp, &rlen, 3000) != AVDTP_MSG_ACCEPT) {
        fprintf(stderr, "FAIL: the headphones didn't answer endpoint discovery\n");
        return;
    }
    avdtp_sep seps[16];
    size_t n = avdtp_parse_discover(resp, rlen, seps, 16);
    printf("%zu endpoint(s):\n", n);
    for (size_t i = 0; i < n; i++) {
        if (seps[i].media_type != 0 || !seps[i].is_sink) continue;
        uint8_t arg = (uint8_t)(seps[i].seid << 2);
        int t = avdtp_request(&av, AVDTP_GET_ALL_CAPABILITIES, &arg, 1, resp, &rlen, 3000);
        if (t != AVDTP_MSG_ACCEPT) t = avdtp_request(&av, AVDTP_GET_CAPABILITIES, &arg, 1, resp, &rlen, 3000);
        a2dp_codec_caps c;
        if (t == AVDTP_MSG_ACCEPT && avdtp_parse_codec(resp, rlen, &c)) printCodec(seps[i].seid, &c);
        else printf("  SEID %u: capabilities request failed\n", seps[i].seid);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <aa:bb:cc:dd:ee:ff>\n", argv[0]);
            return 2;
        }
        NSError *err;
        ClassicSession *s = [[ClassicSession alloc] initWithName:@"btbridge.caps" error:&err];
        NSUUID *dev = s ? [s lookupAddress:@(argv[1]) connected:NULL error:&err] : nil;
        if (!dev) {
            fprintf(stderr, "FAIL: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }

        // From here on the headphones may be ours, so every path ends with a handback.
        L2CAPChannel *sig = [s takeOverAVDTP:dev error:&err];
        BOOL ok = sig != nil;
        if (ok) listCodecs(sig.fd);
        else fprintf(stderr, "FAIL: %s\n", err.localizedDescription.UTF8String);

        [s closeChannelTo:dev psm:kPSMAVDTP];
        sig = nil;
        printf("%s\n", [s handBack:dev] ? "handed back to macOS" : "WARNING: macOS didn't report the headphones reconnected");
        return ok ? 0 : 1;
    }
}
