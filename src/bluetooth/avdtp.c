// SPDX-License-Identifier: GPL-3.0-only
#include "avdtp.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void trace(const avdtp_signaling *s, const char *dir, const uint8_t *b, size_t n) {
    if (!s->trace) return;
    fprintf(stderr, "avdtp %s", dir);
    for (size_t i = 0; i < n; i++) fprintf(stderr, " %02x", b[i]);
    fprintf(stderr, "\n");
}

bool avdtp_parse(const uint8_t *buf, size_t n, avdtp_msg *out) {
    // Only single packets (packet type 0); sinks don't fragment messages this small.
    if (n < 2 || ((buf[0] >> 2) & 0x3) != 0) return false;
    out->label = buf[0] >> 4;
    out->type = buf[0] & 0x3;
    out->signal = buf[1] & 0x3f;
    out->payload = buf + 2;
    out->len = n - 2;
    return true;
}

static bool send_msg(avdtp_signaling *s, uint8_t label, uint8_t type, uint8_t signal, const uint8_t *payload,
                     size_t len) {
    uint8_t buf[AVDTP_MAX_SIGNAL];
    if (len + 2 > sizeof buf) return false;
    buf[0] = (uint8_t)(label << 4 | type);
    buf[1] = signal;
    if (len) memcpy(buf + 2, payload, len);
    trace(s, "tx", buf, len + 2);
    return write(s->fd, buf, len + 2) == (ssize_t)(len + 2);
}

static uint8_t default_response(const avdtp_msg *cmd, uint8_t *resp, size_t *resp_len) {
    switch (cmd->signal) {
    case AVDTP_DELAY_REPORT:
        *resp_len = 0;
        return AVDTP_MSG_ACCEPT;
    default:
        *resp_len = 0;
        return AVDTP_MSG_GENERAL_REJECT;
    }
}

static void answer(avdtp_signaling *s, const avdtp_msg *cmd) {
    uint8_t resp[AVDTP_MAX_SIGNAL];
    size_t resp_len = 0;
    uint8_t type = s->on_command ? s->on_command(s->ctx, cmd, resp, &resp_len) : default_response(cmd, resp, &resp_len);
    send_msg(s, cmd->label, type, cmd->signal, resp, resp_len);
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static bool valid_header(const uint8_t *b, size_t n) {
    if (n < 2 || ((b[0] >> 2) & 0x3) != 0) return false;
    // A general reject echoes whatever signal id it couldn't handle.
    if ((b[0] & 0x3) == AVDTP_MSG_GENERAL_REJECT) return true;
    uint8_t signal = b[1];
    return (signal & 0xc0) == 0 && signal >= AVDTP_DISCOVER && signal <= AVDTP_DELAY_REPORT;
}

// True if p holds nothing but complete, well-formed messages.
static bool whole_messages(const uint8_t *p, size_t n, int depth) {
    while (n) {
        if (depth <= 0 || !valid_header(p, n)) return false;
        size_t len = avdtp_message_length(p, n);
        p += len;
        n -= len;
        depth--;
    }
    return true;
}

// Bytes taken by a run of service-capability records (category 1-8, length, data).
// A reply with label 0 can look like a record, so the run also ends where the rest
// of the buffer reads as complete messages. Real records rarely do: categories 4-8
// have reserved packet-type bits set and a 0-length record reads as signal 0.
static size_t capability_run(const uint8_t *p, size_t n) {
    size_t i = 0;
    while (i + 2 <= n) {
        if (i && whole_messages(p + i, n - i, 4)) break;
        uint8_t cat = p[i], len = p[i + 1];
        if (cat < AVDTP_CAT_MEDIA_TRANSPORT || cat > AVDTP_CAT_DELAY_REPORTING || i + 2 + len > n) break;
        i += 2 + len;
    }
    return i;
}

// Bytes taken by a run of DISCOVER endpoint records (2 bytes each, reserved bits zero).
static size_t endpoint_run(const uint8_t *p, size_t n) {
    size_t i = 0;
    while (i + 2 <= n && (p[i] & 0x01) == 0 && (p[i] >> 2) != 0 && (p[i + 1] & 0x07) == 0 && (p[i + 1] >> 4) <= 2) {
        if (i && whole_messages(p + i, n - i, 4)) break;
        i += 2;
    }
    return i;
}

size_t avdtp_message_length(const uint8_t *b, size_t n) {
    if (!valid_header(b, n)) return n; // not something we can split: treat it as one message
    const uint8_t *p = b + 2;
    size_t m = n - 2, len;
    switch (b[0] & 0x3) {
    case AVDTP_MSG_COMMAND:
        switch (b[1]) {
        case AVDTP_DISCOVER:
            len = 2;
            break;
        case AVDTP_DELAY_REPORT:
            len = 5; // SEID + 16-bit delay
            break;
        case AVDTP_SET_CONFIGURATION:
            len = m >= 2 ? 4 + capability_run(p + 2, m - 2) : n;
            break;
        case AVDTP_RECONFIGURE:
            len = m >= 1 ? 3 + capability_run(p + 1, m - 1) : n;
            break;
        case AVDTP_SECURITY_CONTROL:
            len = n;
            break;
        default: // one SEID (START/SUSPEND may list more, but sinks send one)
            len = 3;
            break;
        }
        break;
    case AVDTP_MSG_ACCEPT:
        switch (b[1]) {
        case AVDTP_DISCOVER:
            len = 2 + endpoint_run(p, m);
            break;
        case AVDTP_GET_CAPABILITIES:
        case AVDTP_GET_ALL_CAPABILITIES:
        case AVDTP_GET_CONFIGURATION:
            len = 2 + capability_run(p, m);
            break;
        case AVDTP_SECURITY_CONTROL:
            len = n;
            break;
        default:
            len = 2;
            break;
        }
        break;
    case AVDTP_MSG_REJECT:
        // Category or SEID + error code for these; just the error code otherwise.
        len = b[1] == AVDTP_SET_CONFIGURATION || b[1] == AVDTP_RECONFIGURE || b[1] == AVDTP_START ||
                      b[1] == AVDTP_SUSPEND
                  ? 4
                  : 3;
        break;
    default:
        len = 2;
        break;
    }
    return len < n ? len : n;
}

// Reads one message, waiting at most timeout_ms. Returns 1 on success, 0 on timeout, -1 on error.
static int read_msg(avdtp_signaling *s, uint8_t *buf, size_t cap, size_t *n, int timeout_ms) {
    if (!s->rx_len) {
        struct pollfd p = {s->fd, POLLIN, 0};
        int r = poll(&p, 1, timeout_ms);
        if (r == 0) return 0;
        if (r < 0) return errno == EINTR ? 0 : -1;
        ssize_t got = read(s->fd, s->rx, sizeof s->rx);
        if (got <= 0) return -1;
        s->rx_len = (size_t)got;
    }
    size_t len = avdtp_message_length(s->rx, s->rx_len);
    if (len > cap) len = cap;
    memcpy(buf, s->rx, len);
    memmove(s->rx, s->rx + len, s->rx_len - len);
    s->rx_len -= len;
    *n = len;
    trace(s, "rx", buf, *n);
    return 1;
}

int avdtp_request(avdtp_signaling *s, uint8_t signal, const uint8_t *payload, size_t len, uint8_t *resp,
                  size_t *resp_len, int timeout_ms) {
    uint8_t label = s->next_label;
    s->next_label = (s->next_label + 1) & 0xf;
    if (!send_msg(s, label, AVDTP_MSG_COMMAND, signal, payload, len)) return -1;

    long deadline = now_ms() + timeout_ms;
    for (;;) {
        long left = deadline - now_ms();
        if (left <= 0) return -1;
        uint8_t buf[AVDTP_MAX_SIGNAL];
        size_t n;
        int r = read_msg(s, buf, sizeof buf, &n, (int)left);
        if (r < 0) return -1;
        if (r == 0) continue;
        avdtp_msg m;
        if (!avdtp_parse(buf, n, &m)) continue;
        if (m.type == AVDTP_MSG_COMMAND) {
            answer(s, &m);
            continue;
        }
        if (m.label != label || (m.signal != signal && m.type != AVDTP_MSG_GENERAL_REJECT)) continue;
        if (resp && resp_len) {
            memcpy(resp, m.payload, m.len);
            *resp_len = m.len;
        }
        return m.type;
    }
}

bool avdtp_service(avdtp_signaling *s, int timeout_ms) {
    uint8_t buf[AVDTP_MAX_SIGNAL];
    size_t n;
    int r = read_msg(s, buf, sizeof buf, &n, timeout_ms);
    if (r < 0) return false;
    avdtp_msg m;
    if (r == 1 && avdtp_parse(buf, n, &m) && m.type == AVDTP_MSG_COMMAND) answer(s, &m);
    return true;
}

size_t avdtp_parse_discover(const uint8_t *payload, size_t len, avdtp_sep *seps, size_t max) {
    size_t count = 0;
    for (size_t i = 0; i + 1 < len && count < max; i += 2) {
        seps[count].seid = payload[i] >> 2;
        seps[count].in_use = (payload[i] >> 1) & 1;
        seps[count].media_type = payload[i + 1] >> 4;
        seps[count].is_sink = (payload[i + 1] >> 3) & 1;
        count++;
    }
    return count;
}

bool avdtp_parse_codec(const uint8_t *caps, size_t len, a2dp_codec_caps *out) {
    memset(out, 0, sizeof *out);
    bool found = false;
    for (size_t i = 0; i + 2 <= len;) {
        uint8_t cat = caps[i], clen = caps[i + 1];
        const uint8_t *d = caps + i + 2;
        if (i + 2 + clen > len) break;
        if (cat == AVDTP_CAT_DELAY_REPORTING) out->delay_reporting = true;
        if (cat == AVDTP_CAT_MEDIA_CODEC && clen >= 2) {
            out->codec_type = d[1];
            const uint8_t *info = d + 2;
            size_t info_len = clen - 2;
            if (out->codec_type == A2DP_CODEC_VENDOR && info_len >= 6) {
                out->vendor_id = (uint32_t)info[0] | info[1] << 8 | info[2] << 16 | (uint32_t)info[3] << 24;
                out->vendor_codec_id = (uint16_t)(info[4] | info[5] << 8);
                info += 6;
                info_len -= 6;
            }
            if (info_len > sizeof out->info) info_len = sizeof out->info;
            memcpy(out->info, info, info_len);
            out->info_len = info_len;
            found = true;
        }
        i += 2 + clen;
    }
    return found;
}

const char *a2dp_codec_name(const a2dp_codec_caps *c) {
    switch (c->codec_type) {
    case A2DP_CODEC_SBC:
        return "SBC";
    case A2DP_CODEC_AAC:
        return "AAC";
    case A2DP_CODEC_VENDOR:
        if (c->vendor_id == A2DP_VENDOR_SONY && c->vendor_codec_id == A2DP_CODEC_LDAC) return "LDAC";
        if (c->vendor_id == A2DP_VENDOR_APTX && c->vendor_codec_id == A2DP_CODEC_APTX) return "aptX";
        if (c->vendor_id == A2DP_VENDOR_APTX_HD && c->vendor_codec_id == A2DP_CODEC_APTX_HD) return "aptX HD";
        return "vendor";
    default:
        return "other";
    }
}
