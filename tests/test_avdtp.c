// SPDX-License-Identifier: GPL-3.0-only
// Splits concatenated AVDTP messages (as one stream read can deliver them) and checks
// every boundary. Messages are real ones captured from a WH-1000XM6.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "avdtp.h"

typedef struct {
    const char *name;
    uint8_t bytes[64];
    size_t len;
} msg;

static const msg kMessages[] = {
    {"DISCOVER accept (3 sinks)", {0x02, 0x01, 0x04, 0x08, 0x08, 0x08, 0x0c, 0x08}, 8},
    {"GET_ALL_CAPS accept (SBC)",
     {0x12, 0x0c, 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x3f, 0xff, 0x02, 0x35, 0x04, 0x02, 0x02, 0x00, 0x08, 0x00},
     18},
    {"GET_ALL_CAPS accept (LDAC)",
     {0x32, 0x0c, 0x01, 0x00, 0x07, 0x0a, 0x00, 0xff, 0x2d, 0x01, 0x00, 0x00, 0xaa, 0x00, 0x3c, 0x07, 0x04, 0x02,
      0x02, 0x00, 0x08, 0x00},
     22},
    {"DISCOVER command from sink", {0x40, 0x01}, 2},
    {"SET_CONFIGURATION accept", {0x42, 0x03}, 2},
    {"DELAY_REPORT command", {0x50, 0x0d, 0x04, 0x07, 0xd0}, 5},
    {"START accept", {0x62, 0x07}, 2},
    {"OPEN reject", {0x73, 0x06, 0x31}, 3},
    {"START reject", {0x83, 0x07, 0x0c, 0x31}, 4},
    {"general reject", {0x91, 0x0e}, 2},
    {"SUSPEND command from sink", {0xa0, 0x09, 0x0c}, 3},
};
#define COUNT (sizeof kMessages / sizeof kMessages[0])

int main(void) {
    int failures = 0;
    // Every ordered pair, glued together, must split back at the right place.
    for (size_t i = 0; i < COUNT; i++) {
        for (size_t j = 0; j < COUNT; j++) {
            uint8_t buf[128];
            memcpy(buf, kMessages[i].bytes, kMessages[i].len);
            memcpy(buf + kMessages[i].len, kMessages[j].bytes, kMessages[j].len);
            size_t total = kMessages[i].len + kMessages[j].len;
            size_t first = avdtp_message_length(buf, total);
            size_t second = avdtp_message_length(buf + first, total - first);
            if (first != kMessages[i].len || second != kMessages[j].len) {
                printf("FAIL: %s + %s split as %zu+%zu, expected %zu+%zu\n", kMessages[i].name, kMessages[j].name,
                       first, second, kMessages[i].len, kMessages[j].len);
                failures++;
            }
        }
    }
    printf("%s: %zu pairs, %d failures\n", failures ? "FAIL" : "OK", COUNT * COUNT, failures);

    // Untrusted input: random and truncated buffers through every parser. Run under
    // -fsanitize=address,undefined (make test-asan) to catch out-of-bounds reads.
    srand(1);
    int fuzzFailures = 0;
    for (int iter = 0; iter < 200000; iter++) {
        uint8_t buf[64];
        size_t n = (size_t)(rand() % (int)sizeof buf);
        for (size_t i = 0; i < n; i++) buf[i] = (uint8_t)rand();
        // Half the time start from a real message so the grammar paths get exercised.
        if (iter & 1) {
            const msg *m = &kMessages[rand() % (int)COUNT];
            size_t keep = m->len < n ? m->len : n;
            memcpy(buf, m->bytes, keep);
        }
        size_t total = 0;
        for (size_t off = 0; off < n;) {
            size_t len = avdtp_message_length(buf + off, n - off);
            if (len == 0 || len > n - off) {
                fuzzFailures++;
                break;
            }
            avdtp_msg msgOut;
            avdtp_parse(buf + off, len, &msgOut);
            off += len;
            total = off;
        }
        if (n && total != n) fuzzFailures++;
        a2dp_codec_caps caps;
        avdtp_parse_codec(buf, n, &caps);
        avdtp_sep seps[16];
        avdtp_parse_discover(buf, n, seps, 16);
    }
    printf("%s: 200000 random buffers, %d failures\n", fuzzFailures ? "FAIL" : "OK", fuzzFailures);
    return failures != 0 || fuzzFailures != 0;
}
