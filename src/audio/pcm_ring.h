// SPDX-License-Identifier: GPL-3.0-only
// Single-producer / single-consumer ring of interleaved stereo float frames, safe to
// write from a Core Audio IO thread without locks.

#pragma once

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    float *data;
    uint32_t capacity; // frames, power of two
    _Atomic uint64_t write_pos;
    _Atomic uint64_t read_pos;
    _Atomic uint64_t dropped; // frames discarded because the consumer fell behind
} pcm_ring;

static inline bool pcm_ring_init(pcm_ring *r, uint32_t capacity_pow2) {
    r->data = calloc((size_t)capacity_pow2 * 2, sizeof(float));
    r->capacity = capacity_pow2;
    atomic_init(&r->write_pos, 0);
    atomic_init(&r->read_pos, 0);
    atomic_init(&r->dropped, 0);
    return r->data != NULL;
}

static inline void pcm_ring_free(pcm_ring *r) {
    free(r->data);
    r->data = NULL;
}

static inline uint32_t pcm_ring_available(pcm_ring *r) {
    return (uint32_t)(atomic_load_explicit(&r->write_pos, memory_order_acquire) -
                      atomic_load_explicit(&r->read_pos, memory_order_acquire));
}

// Producer side. Frames that don't fit are dropped (and counted).
static inline void pcm_ring_write(pcm_ring *r, const float *frames, uint32_t n) {
    uint64_t w = atomic_load_explicit(&r->write_pos, memory_order_relaxed);
    uint32_t space = r->capacity - pcm_ring_available(r);
    if (n > space) {
        atomic_fetch_add_explicit(&r->dropped, n - space, memory_order_relaxed);
        n = space;
    }
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (uint32_t)((w + i) & (r->capacity - 1));
        r->data[2 * idx] = frames[2 * i];
        r->data[2 * idx + 1] = frames[2 * i + 1];
    }
    atomic_store_explicit(&r->write_pos, w + n, memory_order_release);
}

// Consumer side. Discards up to n queued frames.
static inline void pcm_ring_skip(pcm_ring *r, uint32_t n) {
    uint32_t avail = pcm_ring_available(r);
    if (n > avail) n = avail;
    atomic_fetch_add_explicit(&r->read_pos, n, memory_order_release);
}

// Consumer side. Returns false (and reads nothing) if fewer than n frames are queued.
static inline bool pcm_ring_read(pcm_ring *r, float *frames, uint32_t n) {
    if (pcm_ring_available(r) < n) return false;
    uint64_t rd = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (uint32_t)((rd + i) & (r->capacity - 1));
        frames[2 * i] = r->data[2 * idx];
        frames[2 * i + 1] = r->data[2 * idx + 1];
    }
    atomic_store_explicit(&r->read_pos, rd + n, memory_order_release);
    return true;
}
