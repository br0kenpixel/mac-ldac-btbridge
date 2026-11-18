// SPDX-License-Identifier: GPL-3.0-only
// LDAC encoder + A2DP media packetizer: PCM in, RTP packets ready for the AVDTP
// media channel out.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ldac_rtp ldac_rtp;

// Quality: 0 = HQ (990/909 kbps), 1 = SQ (660/606), 2 = MQ (330/303).
// sample_rate: 44100, 48000, 88200 or 96000. Input is interleaved stereo float32.
// Returns NULL for an unsupported rate, an MTU below LDAC_RTP_MIN_MTU, or if libldac
// can't be initialised.
ldac_rtp *ldac_rtp_create(int sample_rate, int quality, int media_mtu);
void ldac_rtp_free(ldac_rtp *e);

// Number of frames (samples per channel) ldac_rtp_encode consumes per call.
#define LDAC_RTP_FRAMES 128

// Smallest media MTU libldac accepts (its 2-DH5 packet size).
#define LDAC_RTP_MIN_MTU 679

// Largest packet ldac_rtp_encode produces: RTP + LDAC headers + libldac's maximum
// transport-frame payload. Output buffers must hold this much.
#define LDAC_RTP_MAX_PACKET (12 + 1 + LDAC_RTP_MIN_MTU)

// Encodes exactly LDAC_RTP_FRAMES frames. When a packet is complete it is written to
// out (which must hold LDAC_RTP_MAX_PACKET bytes) and its length returned; otherwise 0.
// Returns -1 on encoder failure.
int ldac_rtp_encode(ldac_rtp *e, const float *pcm, uint8_t *out);

// LDAC codec-information bytes for SET_CONFIGURATION (sample rate + stereo).
// Returns false for a sample rate LDAC doesn't have.
bool ldac_rtp_config(int sample_rate, uint8_t out[2]);
