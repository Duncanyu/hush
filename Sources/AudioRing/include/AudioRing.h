#ifndef AUDIO_RING_H
#define AUDIO_RING_H

#include <stdint.h>

typedef struct AudioRing AudioRing;
typedef struct {
    uint32_t queuedFrames;
    uint64_t underrunFrames;
    uint64_t skippedFrames;
} AudioRingStats;
AudioRing *AudioRingCreate(uint32_t capacityFrames);
void AudioRingDestroy(AudioRing *ring);
void AudioRingWrite(AudioRing *ring, const float *left, const float *right,
                    uint32_t frames, int interleaved);
void AudioRingRead(AudioRing *ring, float *left, float *right, uint32_t frames);
int AudioRingRecentlyActive(AudioRing *ring);
AudioRingStats AudioRingGetStats(AudioRing *ring);

#endif
