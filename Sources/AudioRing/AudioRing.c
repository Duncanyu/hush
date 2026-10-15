#include "AudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

struct AudioRing {
    uint32_t capacity;
    _Atomic uint64_t written;
    _Atomic uint64_t read;
    _Atomic uint64_t lastSignal;
    _Atomic uint64_t lastWrite;
    _Atomic uint64_t underrunFrames;
    _Atomic uint64_t skippedFrames;
    uint64_t activeWindow;
    uint64_t writeWindow;
    float *samples;
};

AudioRing *AudioRingCreate(uint32_t capacityFrames) {
    AudioRing *ring = calloc(1, sizeof(AudioRing));
    if (!ring) return NULL;
    ring->capacity = capacityFrames;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    ring->activeWindow = 3000000000ULL * timebase.denom / timebase.numer;
    ring->writeWindow = 100000000ULL * timebase.denom / timebase.numer;
    ring->samples = calloc((size_t)capacityFrames * 2, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    return ring;
}

void AudioRingDestroy(AudioRing *ring) {
    if (ring) { free(ring->samples); free(ring); }
}

void AudioRingWrite(AudioRing *ring, const float *left, const float *right,
                    uint32_t frames, int interleaved) {
    if (!ring || !left) return;
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t available = ring->capacity - (uint32_t)(written - read);
    if (frames > available) frames = available; // Drop new frames rather than overwrite live data.
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((written + i) % ring->capacity) * 2;
        ring->samples[slot] = interleaved ? left[i * 2] : left[i];
        ring->samples[slot + 1] = interleaved ? left[i * 2 + 1] : (right ? right[i] : left[i]);
    }
    atomic_store_explicit(&ring->written, written + frames, memory_order_release);
    if (frames) atomic_store_explicit(&ring->lastWrite, mach_absolute_time(), memory_order_relaxed);
}

void AudioRingRead(AudioRing *ring, float *left, float *right, uint32_t frames) {
    if (!ring || !left || !right) return;
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint32_t available = (uint32_t)(written - read);
    // The tap and output device have independent clocks. Keep at most one render
    // buffer queued when they drift, instead of letting latency grow to the ring size.
    if (available > (uint64_t)frames * 2) {
        atomic_fetch_add_explicit(&ring->skippedFrames, available - frames, memory_order_relaxed);
        read = written - frames;
        available = frames;
    }
    uint32_t count = frames < available ? frames : available;
    int hasSignal = 0;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t slot = (uint32_t)((read + i) % ring->capacity) * 2;
        left[i] = ring->samples[slot];
        right[i] = ring->samples[slot + 1];
        if (left[i] > 0.0001f || left[i] < -0.0001f ||
            right[i] > 0.0001f || right[i] < -0.0001f) hasSignal = 1;
    }
    if (hasSignal) atomic_store_explicit(&ring->lastSignal, mach_absolute_time(), memory_order_relaxed);
    if (count < frames) {
        uint64_t lastWrite = atomic_load_explicit(&ring->lastWrite, memory_order_relaxed);
        if (lastWrite && mach_absolute_time() - lastWrite < ring->writeWindow) {
            atomic_fetch_add_explicit(&ring->underrunFrames, frames - count, memory_order_relaxed);
        }
        memset(left + count, 0, (size_t)(frames - count) * sizeof(float));
        memset(right + count, 0, (size_t)(frames - count) * sizeof(float));
    }
    atomic_store_explicit(&ring->read, read + count, memory_order_release);
}

int AudioRingRecentlyActive(AudioRing *ring) {
    if (!ring) return 0;
    uint64_t last = atomic_load_explicit(&ring->lastSignal, memory_order_relaxed);
    return last && mach_absolute_time() - last < ring->activeWindow;
}

AudioRingStats AudioRingGetStats(AudioRing *ring) {
    if (!ring) return (AudioRingStats){0};
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    return (AudioRingStats){
        .queuedFrames = (uint32_t)(written - read),
        .underrunFrames = atomic_load_explicit(&ring->underrunFrames, memory_order_relaxed),
        .skippedFrames = atomic_load_explicit(&ring->skippedFrames, memory_order_relaxed),
    };
}
