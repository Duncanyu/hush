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
    _Atomic uint32_t peakQueuedFrames;
    _Atomic uint64_t lastTiming;
    _Atomic uint32_t tapToSourceRenderUs;
    _Atomic uint64_t timingStart;
    _Atomic int timingEnabled;
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
    double hostTicksPerFrame;
    double hostTicksToUs;
    float *samples;
    uint64_t *captureTimes;
};

static uint32_t elapsedUs(const AudioRing *ring, uint64_t later, uint64_t earlier) {
    if (!earlier || later < earlier) return 0;
    double us = (double)(later - earlier) * ring->hostTicksToUs;
    return us < 10000000 ? (uint32_t)us : 0;
}

AudioRing *AudioRingCreate(uint32_t capacityFrames) {
    AudioRing *ring = calloc(1, sizeof(AudioRing));
    if (!ring) return NULL;
    ring->capacity = capacityFrames;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    ring->activeWindow = 3000000000ULL * timebase.denom / timebase.numer;
    ring->writeWindow = 100000000ULL * timebase.denom / timebase.numer;
    ring->hostTicksToUs = (double)timebase.numer / timebase.denom / 1000.0;
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
    // Optional timing metadata never affects the audio path.
    ring->captureTimes = calloc(capacityFrames, sizeof(uint64_t));
    return ring;
}

void AudioRingSetSampleRate(AudioRing *ring, double sampleRate) {
    if (ring && sampleRate > 0) {
        ring->hostTicksPerFrame = 1000000.0 / (sampleRate * ring->hostTicksToUs);
    }
}

void AudioRingSetTimingEnabled(AudioRing *ring, int enabled) {
    if (!ring) return;
    atomic_store_explicit(&ring->timingEnabled, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->lastTiming, 0, memory_order_relaxed);
    if (enabled) {
        atomic_store_explicit(&ring->timingStart, mach_absolute_time(), memory_order_relaxed);
        atomic_store_explicit(&ring->timingEnabled, 1, memory_order_release);
    }
}

void AudioRingSetAnalysisEnabled(AudioRing *ring, int enabled) {
    if (ring) atomic_store_explicit(&ring->analysisEnabled, enabled != 0, memory_order_relaxed);
}

void AudioRingDestroy(AudioRing *ring) {
    if (ring) {
        free(ring->captureTimes);
        free(ring->samples);
        free(ring);
    }
}

void AudioRingWrite(AudioRing *ring, const float *left, const float *right,
                    uint32_t frames, int interleaved) {
    AudioRingWriteTimed(ring, left, right, frames, interleaved, 0);
}

void AudioRingWriteTimed(AudioRing *ring, const float *left, const float *right,
                         uint32_t frames, int interleaved, uint64_t captureHostTime) {
    if (!ring || !left) return;
    uint64_t callbackTime = mach_absolute_time();
    int timed = atomic_load_explicit(&ring->timingEnabled, memory_order_acquire) &&
                ring->captureTimes && ring->hostTicksPerFrame > 0;
    int timestampValid = timed && captureHostTime && captureHostTime <= callbackTime;
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t available = ring->capacity - (uint32_t)(written - read);
    if (frames > available) frames = available; // Drop new frames rather than overwrite live data.
    int analysisEnabled = atomic_load_explicit(&ring->analysisEnabled, memory_order_relaxed);
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((written + i) % ring->capacity) * 2;
        float leftSample = interleaved ? left[i * 2] : left[i];
        float rightSample = interleaved ? left[i * 2 + 1] : (right ? right[i] : leftSample);
        ring->samples[slot] = leftSample;
        ring->samples[slot + 1] = rightSample;
        if (timed) {
            // Follow the exact frame through partial reads and backlog trims.
            uint32_t frameSlot = slot / 2;
            ring->captureTimes[frameSlot] = timestampValid
                ? captureHostTime + (uint64_t)(i * ring->hostTicksPerFrame) : 0;
        }
        if (!analysisEnabled) continue;
        if (++ring->analysisDecimation < 2) continue;
        ring->analysisDecimation = 0;
        float peak = fmaxf(fabsf(leftSample), fabsf(rightSample));
        float sample = (leftSample + rightSample) * 0.5f;
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
    if (frames) {
        atomic_store_explicit(&ring->lastWrite, callbackTime, memory_order_relaxed);
    }
}

void AudioRingRead(AudioRing *ring, float *left, float *right, uint32_t frames) {
    AudioRingReadTimed(ring, left, right, frames, 0);
}

void AudioRingReadTimed(AudioRing *ring, float *left, float *right,
                        uint32_t frames, uint64_t renderHostTime) {
    if (!ring || !left || !right) return;
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint32_t available = (uint32_t)(written - read);
    uint32_t peak = atomic_load_explicit(&ring->peakQueuedFrames, memory_order_relaxed);
    while (available > peak && !atomic_compare_exchange_weak_explicit(
               &ring->peakQueuedFrames, &peak, available, memory_order_relaxed, memory_order_relaxed)) {}
    // The tap and output can run on independent clocks. Allow up to three
    // render buffers of backlog, then trim to two. Do not delay startup for
    // a prefill: a short sound may contain less than one buffer of audio.
    if (available > (uint64_t)frames * 3) {
        uint32_t target = frames * 2;
        atomic_fetch_add_explicit(&ring->skippedFrames, available - target, memory_order_relaxed);
        read = written - target;
        available = target;
    }
    uint32_t count = frames < available ? frames : available;
    if (count && ring->captureTimes && renderHostTime &&
        atomic_load_explicit(&ring->timingEnabled, memory_order_acquire)) {
        uint32_t slot = (uint32_t)(read % ring->capacity);
        uint64_t stamp = ring->captureTimes[slot];
        uint64_t timingStart = atomic_load_explicit(&ring->timingStart, memory_order_relaxed);
        uint32_t delay = stamp >= timingStart ? elapsedUs(ring, renderHostTime, stamp) : 0;
        if (delay) {
            atomic_store_explicit(&ring->tapToSourceRenderUs, delay, memory_order_relaxed);
            atomic_store_explicit(&ring->lastTiming, mach_absolute_time(), memory_order_release);
        }
    }
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
    uint32_t queued = (uint32_t)(written - read);
    uint32_t peakQueued = atomic_exchange_explicit(&ring->peakQueuedFrames, 0, memory_order_relaxed);
    AudioRingStats result = {
        .queuedFrames = queued,
        .peakQueuedFrames = peakQueued > queued ? peakQueued : queued,
        .underrunFrames = atomic_load_explicit(&ring->underrunFrames, memory_order_relaxed),
        .skippedFrames = atomic_load_explicit(&ring->skippedFrames, memory_order_relaxed),
        .peakLevel = peak,
    };
    uint64_t lastTiming = atomic_load_explicit(&ring->lastTiming, memory_order_acquire);
    if (atomic_load_explicit(&ring->timingEnabled, memory_order_relaxed) &&
        lastTiming && mach_absolute_time() - lastTiming < ring->activeWindow) {
        result.tapToSourceRenderUs = atomic_load_explicit(&ring->tapToSourceRenderUs, memory_order_relaxed);
    }
    for (int band = 0; band < 8; band++) {
        uint32_t bits = atomic_exchange_explicit(&ring->bandBits[band], 0, memory_order_relaxed);
        memcpy(&result.bandLevels[band], &bits, sizeof(float));
    }
    return result;
}
