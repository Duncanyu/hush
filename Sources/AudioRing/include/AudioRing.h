#ifndef AUDIO_RING_H
#define AUDIO_RING_H

#include <stdint.h>

typedef struct AudioRing AudioRing;
typedef struct {
    uint32_t queuedFrames;
    uint32_t peakQueuedFrames;
    uint64_t underrunFrames;
    uint64_t skippedFrames;
    uint32_t tapToSourceRenderUs;
    float peakLevel;
    float bandLevels[8];
} AudioRingStats;
AudioRing *AudioRingCreate(uint32_t capacityFrames);
void AudioRingSetSampleRate(AudioRing *ring, double sampleRate);
void AudioRingSetTimingEnabled(AudioRing *ring, int enabled);
void AudioRingDestroy(AudioRing *ring);
void AudioRingWrite(AudioRing *ring, const float *left, const float *right,
                    uint32_t frames, int interleaved);
void AudioRingWriteTimed(AudioRing *ring, const float *left, const float *right,
                         uint32_t frames, int interleaved, uint64_t captureHostTime);
void AudioRingRead(AudioRing *ring, float *left, float *right, uint32_t frames);
void AudioRingReadTimed(AudioRing *ring, float *left, float *right,
                        uint32_t frames, uint64_t renderHostTime);
void AudioRingSetAnalysisEnabled(AudioRing *ring, int enabled);
int AudioRingRecentlyActive(AudioRing *ring);
AudioRingStats AudioRingGetStats(AudioRing *ring);

#endif
