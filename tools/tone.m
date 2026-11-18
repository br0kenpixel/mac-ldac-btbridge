// SPDX-License-Identifier: GPL-3.0-only
// tone: take over the headphones, play a 440 Hz sine over LDAC, then hand them back.
// A minimal end-to-end check of the Bluetooth side without system audio capture.
//
//   tone <aa:bb:cc:dd:ee:ff> [seconds=5] [rate=48000] [quality 0=HQ 1=SQ 2=MQ]

#import <Foundation/Foundation.h>

#include <math.h>
#include <time.h>
#include <unistd.h>

#import "A2DPLink.h"
#import "ClassicSession.h"
#include "ldac_rtp.h"

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// Streams the tone until `seconds` pass or the headphones end the stream.
static BOOL playTone(A2DPLink *link, ldac_rtp *enc, int rate, double seconds) {
    float pcm[LDAC_RTP_FRAMES * 2];
    uint8_t pkt[LDAC_RTP_MAX_PACKET];
    double phase = 0, step = 2 * M_PI * 440 / rate;
    long framesSent = 0, packets = 0, bytes = 0;
    const double lead = 0.040; // keep this much audio ahead of real time
    double t0 = now();
    while (now() - t0 < seconds && !link.interrupted) {
        // Produce whatever is due, then sleep briefly: packets go out ~one at a time.
        while (framesSent < (now() - t0 + lead) * rate) {
            for (int i = 0; i < LDAC_RTP_FRAMES; i++) {
                float v = 0.2f * (float)sin(phase);
                phase += step;
                pcm[2 * i] = pcm[2 * i + 1] = v;
            }
            framesSent += LDAC_RTP_FRAMES;
            int n = ldac_rtp_encode(enc, pcm, pkt);
            if (n < 0) {
                fprintf(stderr, "FAIL: LDAC encoder error\n");
                return NO;
            }
            if (n == 0) continue;
            if (write(link.mediaFd, pkt, (size_t)n) != n) {
                fprintf(stderr, "FAIL: the headphones stopped accepting audio\n");
                return NO;
            }
            packets++;
            bytes += n;
        }
        usleep(2000);
    }
    printf("sent %ld packets, %.0f kbps%s\n", packets, bytes * 8 / 1000.0 / (now() - t0),
           link.interrupted ? " (headphones ended the stream)" : "");
    return !link.interrupted;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <aa:bb:cc:dd:ee:ff> [seconds] [rate] [quality 0-2]\n", argv[0]);
            return 2;
        }
        double seconds = argc > 2 ? atof(argv[2]) : 5;
        int rate = argc > 3 ? atoi(argv[3]) : 48000;
        int quality = argc > 4 ? atoi(argv[4]) : 0;

        NSError *err;
        ClassicSession *s = [[ClassicSession alloc] initWithName:@"btbridge.tone" error:&err];
        NSUUID *dev = s ? [s lookupAddress:@(argv[1]) connected:NULL error:&err] : nil;
        if (!dev) {
            fprintf(stderr, "FAIL: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }

        // From here on the headphones may be ours, so every path ends with a handback.
        BOOL ok = NO;
        ldac_rtp *enc = NULL;
        L2CAPChannel *sig = [s takeOverAVDTP:dev error:&err];
        A2DPLink *link = sig ? [[A2DPLink alloc] initWithDevice:dev signaling:sig] : nil;
        if (link && [link startLDACAtRate:rate error:&err]) {
            printf("streaming LDAC %d Hz, quality %d, media MTU %u\n", rate, quality, link.mediaMTU);
            enc = ldac_rtp_create(rate, quality, link.mediaMTU);
            if (enc) ok = playTone(link, enc, rate, seconds);
            else fprintf(stderr, "FAIL: couldn't set up the LDAC encoder\n");
        } else {
            fprintf(stderr, "FAIL: %s\n", err.localizedDescription.UTF8String);
        }

        ldac_rtp_free(enc);
        [link stop];
        [s closeChannelTo:dev psm:kPSMAVDTP];
        link = nil;
        sig = nil;
        printf("%s\n", [s handBack:dev] ? "handed back to macOS" : "WARNING: macOS didn't report the headphones reconnected");
        return ok ? 0 : 1;
    }
}
