#ifndef LUMARING_TRACKPAD_INPUT_H
#define LUMARING_TRACKPAD_INPUT_H
#include <stdbool.h>
#include <stdint.h>

// Small value types shared with tests. Coordinates are normalized to the pad.
typedef struct { int32_t id, state; float x, y; } LRContact;
typedef struct {
    LRContact origins[4];
    double began, fourAt, releasedAt, lastFrame, lastTap;
    unsigned count, previousMask;
    bool armed, tracking, blocked, hadFour, releasing;
} LRTapRecognizer;

// Reset requires an all-fingers-up frame before accepting a new gesture.
void LRTapReset(LRTapRecognizer *recognizer);
bool LRTapFrame(LRTapRecognizer *recognizer, const LRContact *contacts, int count, double timestamp);

typedef void (*LRTapCallback)(uint64_t generation);
typedef struct { uint64_t generation; int devices; bool available; } LRTrackpadResult;
typedef struct { uint64_t frames, taps; int devices; } LRTrackpadStatistics;

// Start/stop on a single owner queue. Callback runs on the device thread and
// must not call these functions. Stop fences in-flight callbacks.
LRTrackpadResult LRTrackpadStart(LRTapCallback callback);
void LRTrackpadStop(void);
LRTrackpadStatistics LRTrackpadGetStatistics(void);
#endif
