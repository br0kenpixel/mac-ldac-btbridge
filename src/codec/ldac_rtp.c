// SPDX-License-Identifier: GPL-3.0-only
#include "ldac_rtp.h"

#include <stdlib.h>
#include <string.h>

#include "ldacBT.h"

#define RTP_HEADER 12
#define LDAC_MEDIA_HEADER 1
#define RTP_PAYLOAD_TYPE 96

struct ldac_rtp {
    HANDLE_LDAC_BT h;
    uint16_t seq;
    uint32_t timestamp;
    uint32_t pending_frames; // PCM frames encoded since the last emitted packet
};

bool ldac_rtp_config(int sample_rate, uint8_t out[2]) {
    switch (sample_rate) {
    case 44100:
        out[0] = LDACBT_SAMPLING_FREQ_044100;
        break;
    case 48000:
        out[0] = LDACBT_SAMPLING_FREQ_048000;
        break;
    case 88200:
        out[0] = LDACBT_SAMPLING_FREQ_088200;
        break;
    case 96000:
        out[0] = LDACBT_SAMPLING_FREQ_096000;
        break;
    default:
        return false;
    }
    out[1] = LDACBT_CHANNEL_MODE_STEREO;
    return true;
}

ldac_rtp *ldac_rtp_create(int sample_rate, int quality, int media_mtu) {
    uint8_t cfg[2];
    if (!ldac_rtp_config(sample_rate, cfg) || media_mtu < LDAC_RTP_MIN_MTU) return NULL;
    ldac_rtp *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->h = ldacBT_get_handle();
    static const int eqmids[] = {LDACBT_EQMID_HQ, LDACBT_EQMID_SQ, LDACBT_EQMID_MQ};
    int eqmid = eqmids[quality < 0 || quality > 2 ? 0 : quality];
    if (!e->h || ldacBT_init_handle_encode(e->h, media_mtu, eqmid, LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32,
                                           sample_rate) != 0) {
        ldac_rtp_free(e);
        return NULL;
    }
    e->seq = (uint16_t)arc4random();
    e->timestamp = arc4random();
    return e;
}

void ldac_rtp_free(ldac_rtp *e) {
    if (!e) return;
    if (e->h) ldacBT_free_handle(e->h);
    free(e);
}

int ldac_rtp_encode(ldac_rtp *e, const float *pcm, uint8_t *out) {
    uint8_t *stream = out + RTP_HEADER + LDAC_MEDIA_HEADER;
    int used = 0, written = 0, frames = 0;
    if (ldacBT_encode(e->h, (void *)pcm, &used, stream, &written, &frames) != 0) return -1;
    e->pending_frames += LDAC_RTP_FRAMES;
    if (written <= 0) return 0;
    if (written > LDAC_RTP_MAX_PACKET - RTP_HEADER - LDAC_MEDIA_HEADER) return -1; // can't happen per libldac

    out[0] = 0x80; // RTP version 2
    out[1] = RTP_PAYLOAD_TYPE;
    out[2] = (uint8_t)(e->seq >> 8);
    out[3] = (uint8_t)e->seq;
    out[4] = (uint8_t)(e->timestamp >> 24);
    out[5] = (uint8_t)(e->timestamp >> 16);
    out[6] = (uint8_t)(e->timestamp >> 8);
    out[7] = (uint8_t)e->timestamp;
    memset(out + 8, 0, 3);
    out[11] = 1; // SSRC
    out[RTP_HEADER] = (uint8_t)(frames & 0x0f);
    e->seq++;
    e->timestamp += e->pending_frames;
    e->pending_frames = 0;
    return RTP_HEADER + LDAC_MEDIA_HEADER + written;
}
