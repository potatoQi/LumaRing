#ifndef LUMARING_TRACKPAD_INPUT_H
#define LUMARING_TRACKPAD_INPUT_H
#include <stdbool.h>
#include <stdint.h>

// Small value types shared with tests. Coordinates are normalized to the pad.
typedef struct { int32_t id, state; float x, y; } LRContact;
typedef struct {
    LRContact origins[4];
    double began, matchedAt, releasedAt, lastFrame, lastTap;
    unsigned count, previousMask, targetCount;
    bool armed, tracking, blocked, matched, releasing;
} LRTapRecognizer;

// Reset requires an all-fingers-up frame before accepting a new gesture.
void LRTapResetForFingerCount(LRTapRecognizer *recognizer, unsigned fingers);
bool LRTapFrame(LRTapRecognizer *recognizer, const LRContact *contacts, int count, double timestamp);

typedef enum { LRPinchNone, LRPinchBegan, LRPinchCancelled, LRPinchCompleted } LRPinchEvent;
typedef struct {
    LRContact origins[3], latest[3];
    double began, releasedAt, lastFrame, lastPinch;
    float bestRatio;
    unsigned count, previousMask;
    bool armed, tracking, blocked, announced, releasing, qualified;
} LRPinchRecognizer;
void LRPinchReset(LRPinchRecognizer *recognizer);
LRPinchEvent LRPinchFrame(LRPinchRecognizer *recognizer, const LRContact *contacts, int count, double timestamp);
typedef void (*LRPinchCallback)(uint64_t generation, int device, LRPinchEvent event);

typedef void (*LRTapCallback)(uint64_t generation);
typedef struct { uint64_t generation; int devices; bool available; } LRTrackpadResult;
typedef struct { uint64_t frames, taps; int devices; } LRTrackpadStatistics;

// Start/stop on a single owner queue. Callback runs on the device thread and
// must not call these functions. Stop fences in-flight callbacks.
LRTrackpadResult LRTrackpadStartConfigured(LRTapCallback tap, LRPinchCallback pinch, unsigned tapFingers);
void LRTrackpadStop(void);
LRTrackpadStatistics LRTrackpadGetStatistics(void);
#endif
