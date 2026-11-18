// SPDX-License-Identifier: GPL-3.0-only
// Minimal AVDTP (Bluetooth A/V Distribution Transport Protocol) signaling for an
// A2DP source talking to one sink over an L2CAP socket.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    AVDTP_DISCOVER = 0x01,
    AVDTP_GET_CAPABILITIES = 0x02,
    AVDTP_SET_CONFIGURATION = 0x03,
    AVDTP_GET_CONFIGURATION = 0x04,
    AVDTP_RECONFIGURE = 0x05,
    AVDTP_OPEN = 0x06,
    AVDTP_START = 0x07,
    AVDTP_CLOSE = 0x08,
    AVDTP_SUSPEND = 0x09,
    AVDTP_ABORT = 0x0a,
    AVDTP_SECURITY_CONTROL = 0x0b,
    AVDTP_GET_ALL_CAPABILITIES = 0x0c,
    AVDTP_DELAY_REPORT = 0x0d,
};

enum {
    AVDTP_MSG_COMMAND = 0,
    AVDTP_MSG_GENERAL_REJECT = 1,
    AVDTP_MSG_ACCEPT = 2,
    AVDTP_MSG_REJECT = 3,
};

// Service categories inside capability / configuration payloads.
enum {
    AVDTP_CAT_MEDIA_TRANSPORT = 0x01,
    AVDTP_CAT_MEDIA_CODEC = 0x07,
    AVDTP_CAT_DELAY_REPORTING = 0x08,
};

enum {
    A2DP_CODEC_SBC = 0x00,
    A2DP_CODEC_AAC = 0x02,
    A2DP_CODEC_VENDOR = 0xff,
};

#define A2DP_VENDOR_SONY 0x0000012du
#define A2DP_CODEC_LDAC 0x00aa
#define A2DP_VENDOR_APTX 0x0000004fu
#define A2DP_CODEC_APTX 0x0001
#define A2DP_VENDOR_APTX_HD 0x000000d7u
#define A2DP_CODEC_APTX_HD 0x0024

#define AVDTP_MAX_SIGNAL 1024

typedef struct {
    uint8_t label;
    uint8_t type;
    uint8_t signal;
    const uint8_t *payload;
    size_t len;
} avdtp_msg;

typedef struct {
    uint8_t seid;
    bool in_use;
    uint8_t media_type; // 0 = audio
    bool is_sink;
} avdtp_sep;

// One media codec capability as advertised by a sink endpoint.
typedef struct {
    uint8_t codec_type; // A2DP_CODEC_*
    uint32_t vendor_id; // vendor codecs only
    uint16_t vendor_codec_id;
    uint8_t info[32]; // codec-specific bytes after the type (and vendor ids)
    size_t info_len;
    bool delay_reporting;
} a2dp_codec_caps;

// Called for commands the sink sends us while we're waiting for a response; it
// writes the response payload into resp and returns the message type to answer with.
typedef uint8_t (*avdtp_command_handler)(void *ctx, const avdtp_msg *cmd, uint8_t *resp, size_t *resp_len);

typedef struct {
    int fd;
    uint8_t next_label;
    avdtp_command_handler on_command;
    void *ctx;
    bool trace;
    // The channel is a byte stream, so one read can hold several messages; the
    // ones not consumed yet wait here.
    uint8_t rx[2 * AVDTP_MAX_SIGNAL];
    size_t rx_len;
} avdtp_signaling;

bool avdtp_parse(const uint8_t *buf, size_t n, avdtp_msg *out);

// Length of the first message in buf. AVDTP has no length field, so this follows the
// protocol's grammar for each signal and message type (see avdtp.c).
size_t avdtp_message_length(const uint8_t *buf, size_t n);

// Sends a command and blocks until its response arrives (or timeout_ms passes).
// The response payload is copied into resp, which must hold AVDTP_MAX_SIGNAL bytes.
// Returns the response message type, or -1 on I/O error / timeout.
int avdtp_request(avdtp_signaling *s, uint8_t signal, const uint8_t *payload, size_t len, uint8_t *resp,
                  size_t *resp_len, int timeout_ms);

// Waits up to timeout_ms for one incoming command and answers it. Returns false on
// I/O error (the channel is gone).
bool avdtp_service(avdtp_signaling *s, int timeout_ms);

size_t avdtp_parse_discover(const uint8_t *payload, size_t len, avdtp_sep *seps, size_t max);
bool avdtp_parse_codec(const uint8_t *caps, size_t len, a2dp_codec_caps *out);
const char *a2dp_codec_name(const a2dp_codec_caps *c);
