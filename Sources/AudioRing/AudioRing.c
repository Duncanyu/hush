#include "AudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

struct AudioRing {
    uint32_t capacity;
    _Atomic uint64_t written;
    _Atomic uint64_t read;
    _Atomic uint64_t lastSignal;
    _Atomic uint64_t lastWrite;
    _Atomic uint64_t underrunFrames;
    _Atomic uint64_t skippedFrames;
    _Atomic uint32_t peakBits;
    _Atomic int analysisEnabled;
    _Atomic uint32_t bandBits[8];
    float bandReal[8];
    float bandImag[8];
    float bandCos[8];
    float bandSin[8];
    float bandStepCos[8];
    float bandStepSin[8];
    uint32_t bandFrame;
    uint32_t analysisDecimation;
    float analysisPeak;
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
    const float normalizedFrequencies[8] = { 0.00125f, 0.0031f, 0.0078f, 0.0156f,
                                             0.03125f, 0.0625f, 0.125f, 0.25f };
    for (int i = 0; i < 8; i++) {
        float phase = 2.0f * (float)M_PI * normalizedFrequencies[i] * 2.0f;
        ring->bandCos[i] = 1;
        ring->bandSin[i] = 0;
        ring->bandStepCos[i] = cosf(phase);
        ring->bandStepSin[i] = sinf(phase);
    }

    ring->samples = calloc((size_t)capacityFrames * 2, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    return ring;
}

void AudioRingSetAnalysisEnabled(AudioRing *ring, int enabled) {
    if (ring) atomic_store_explicit(&ring->analysisEnabled, enabled != 0, memory_order_relaxed);
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
    int analysisEnabled = atomic_load_explicit(&ring->analysisEnabled, memory_order_relaxed);
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((written + i) % ring->capacity) * 2;
        ring->samples[slot] = interleaved ? left[i * 2] : left[i];
        ring->samples[slot + 1] = interleaved ? left[i * 2 + 1] : (right ? right[i] : left[i]);
        if (!analysisEnabled) continue;
        if (++ring->analysisDecimation < 2) continue;
        ring->analysisDecimation = 0;
        float leftAbs = left[i * 2 + (interleaved ? 0 : 0)];
        float rightAbs = interleaved ? left[i * 2 + 1] : (right ? right[i] : left[i]);
        float peak = fabsf(leftAbs) > fabsf(rightAbs) ? fabsf(leftAbs) : fabsf(rightAbs);
        float sample = (leftAbs + rightAbs) * 0.5f;
        for (int band = 0; band < 8; band++) {
            ring->bandReal[band] += sample * ring->bandCos[band];
            ring->bandImag[band] += sample * ring->bandSin[band];
            float nextCos = ring->bandCos[band] * ring->bandStepCos[band] -
                            ring->bandSin[band] * ring->bandStepSin[band];
            ring->bandSin[band] = ring->bandSin[band] * ring->bandStepCos[band] +
                                  ring->bandCos[band] * ring->bandStepSin[band];
            ring->bandCos[band] = nextCos;
        }
        ring->bandFrame++;
        if (ring->bandFrame == 256) {
            for (int band = 0; band < 8; band++) {
                float magnitude = sqrtf(ring->bandReal[band] * ring->bandReal[band] +
                                        ring->bandImag[band] * ring->bandImag[band]);
                float level = fminf(1.0f, magnitude * 5.0f / 256.0f);
                uint32_t oldBits = atomic_load_explicit(&ring->bandBits[band], memory_order_relaxed);
                float oldLevel;
                memcpy(&oldLevel, &oldBits, sizeof(oldLevel));
                while (level > oldLevel) {
                    uint32_t newBits;
                    memcpy(&newBits, &level, sizeof(newBits));
                    if (atomic_compare_exchange_weak_explicit(&ring->bandBits[band], &oldBits, newBits,
                                                               memory_order_relaxed, memory_order_relaxed)) break;
                    memcpy(&oldLevel, &oldBits, sizeof(oldLevel));
                }
                ring->bandReal[band] = 0;
                ring->bandImag[band] = 0;
            }
            uint32_t peakBits;
            memcpy(&peakBits, &ring->analysisPeak, sizeof(peakBits));
            atomic_store_explicit(&ring->peakBits, peakBits, memory_order_relaxed);
            ring->analysisPeak = 0;
            ring->bandFrame = 0;
        }
        ring->analysisPeak = fmaxf(ring->analysisPeak, peak);
    }
    atomic_store_explicit(&ring->written, written + frames, memory_order_release);
    if (frames) atomic_store_explicit(&ring->lastWrite, mach_absolute_time(), memory_order_relaxed);
}

void AudioRingRead(AudioRing *ring, float *left, float *right, uint32_t frames) {
    if (!ring || !left || !right) return;
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint32_t available = (uint32_t)(written - read);
    // The tap and output device have independent clocks. Keep two render
    // buffers queued and tolerate an additional buffer of timing slack. When
    // correction is needed, discard only the excess rather than the whole
    // backlog so clock correction cannot create a large discontinuity.
    if (available > (uint64_t)frames * 3) {
        uint32_t target = frames * 2;
        atomic_fetch_add_explicit(&ring->skippedFrames, available - target, memory_order_relaxed);
        read = written - target;
        available = target;
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
    uint32_t peakBits = atomic_exchange_explicit(&ring->peakBits, 0, memory_order_relaxed);
    float peak = 0;
    memcpy(&peak, &peakBits, sizeof(peak));
    AudioRingStats result = {
        .queuedFrames = (uint32_t)(written - read),
        .underrunFrames = atomic_load_explicit(&ring->underrunFrames, memory_order_relaxed),
        .skippedFrames = atomic_load_explicit(&ring->skippedFrames, memory_order_relaxed),
        .peakLevel = peak,
    };
    for (int band = 0; band < 8; band++) {
        uint32_t bits = atomic_exchange_explicit(&ring->bandBits[band], 0, memory_order_relaxed);
        memcpy(&result.bandLevels[band], &bits, sizeof(float));
    }
    return result;
}
