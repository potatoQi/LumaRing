#include "TrackpadInput.h"
#include "MultitouchABI.h"
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

// A single process-wide listener. All callback state has static lifetime, so a
// late private-framework callback cannot dereference released Swift objects.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static void *framework;
static CFArrayRef devices;
static struct { MTDeviceRef device; LRTapRecognizer recognizer; LRPinchRecognizer pinch; } slots[16];
static int slotCount;
static uint64_t generation, frames, taps;
static LRTapCallback onTap;
static LRPinchCallback onPinch;
static CFArrayRef (*createList)(void);
static int32_t (*startDevice)(MTDeviceRef, int);
static int32_t (*stopDevice)(MTDeviceRef);
static bool (*isRunning)(MTDeviceRef);
static void (*registerFrame)(MTDeviceRef, MTFrameCallback);
static void (*unregisterFrame)(MTDeviceRef, MTFrameCallback);

static bool loadFramework(void) {
    if (framework) return createList && startDevice && stopDevice && isRunning && registerFrame && unregisterFrame;
    framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LOCAL | RTLD_LAZY);
    if (!framework) return false;
    createList = dlsym(framework, "MTDeviceCreateList");
    startDevice = dlsym(framework, "MTDeviceStart");
    stopDevice = dlsym(framework, "MTDeviceStop");
    isRunning = dlsym(framework, "MTDeviceIsRunning");
    registerFrame = dlsym(framework, "MTRegisterContactFrameCallback");
    unregisterFrame = dlsym(framework, "MTUnregisterContactFrameCallback");
    // Keep the system image mapped for process lifetime; queued callbacks may
    // still return into it after unregistration. Missing symbols fail closed.
    return createList && startDevice && stopDevice && isRunning && registerFrame && unregisterFrame;
}

static void frameCallback(MTDeviceRef device, MTTouch *touches, int count, double time, int frame) {
    (void)frame;
    pthread_mutex_lock(&lock);
    if (!onTap && !onPinch) { pthread_mutex_unlock(&lock); return; }
    for (int i = 0; i < slotCount; ++i) {
        if (slots[i].device != device) continue;
        ++frames;
        LRContact contacts[16];
        if (count < 0 || count > 16 || (count && !touches)) {
            LRTapResetForFingerCount(&slots[i].recognizer, slots[i].recognizer.targetCount);
            if (onPinch && slots[i].pinch.announced && !slots[i].pinch.blocked)
                onPinch(generation, i, LRPinchCancelled);
            LRPinchReset(&slots[i].pinch);
            break;
        }
        for (int j = 0; j < count; ++j)
            contacts[j] = (LRContact){touches[j].identifier, touches[j].state,
                touches[j].normalizedPosition.position.x, touches[j].normalizedPosition.position.y};
        if (onTap && LRTapFrame(&slots[i].recognizer, contacts, count, time)) {
            ++taps;
            // The Swift callback only enqueues one main-thread action. Holding
            // this lock fences delivery against disable/stop without frame tasks.
            onTap(generation);
        }
        if (onPinch) {
            LRPinchEvent event = LRPinchFrame(&slots[i].pinch, contacts, count, time);
            if (event != LRPinchNone) onPinch(generation, i, event);
        }
        break;
    }
    pthread_mutex_unlock(&lock);
}

void LRTrackpadStop(void) {
    pthread_mutex_lock(&lock);
    onTap = NULL;
    onPinch = NULL;
    ++generation;
    pthread_mutex_unlock(&lock);
    // Never hold the callback lock across private start/stop calls: the driver
    // may wait for its own delivery queue to drain.
    for (int i = 0; i < slotCount; ++i) {
        unregisterFrame(slots[i].device, frameCallback);
        stopDevice(slots[i].device);
    }
    pthread_mutex_lock(&lock);
    slotCount = 0;
    memset(slots, 0, sizeof(slots));
    pthread_mutex_unlock(&lock);
    if (devices) { CFRelease(devices); devices = NULL; }
}

LRTrackpadResult LRTrackpadStartConfigured(LRTapCallback callback, LRPinchCallback pinchCallback, unsigned tapFingers) {
    LRTrackpadStop();
    LRTrackpadResult result = {.generation = generation};
    if (tapFingers != 3 && tapFingers != 4) callback = NULL;
    if ((!callback && !pinchCallback) || !loadFramework()) return result;
    result.available = true;
    devices = createList();
    if (!devices) return result;
    MTDeviceRef started[16];
    int startedCount = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(devices) && i < 16; ++i) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
        if (!device) continue;
        registerFrame(device, frameCallback);
        startDevice(device, 0);
        if (isRunning(device)) started[startedCount++] = device;
        else { unregisterFrame(device, frameCallback); stopDevice(device); }
    }
    // Ignore startup frames until every device has started. Publish the complete
    // inventory under the callback lock, including for concurrent statistics reads.
    pthread_mutex_lock(&lock);
    slotCount = startedCount;
    for (int i = 0; i < slotCount; ++i) {
        slots[i].device = started[i];
        LRTapResetForFingerCount(&slots[i].recognizer, tapFingers);
        LRPinchReset(&slots[i].pinch);
    }
    frames = taps = 0;
    onTap = slotCount ? callback : NULL;
    onPinch = slotCount ? pinchCallback : NULL;
    pthread_mutex_unlock(&lock);
    result.devices = startedCount;
    if (!result.devices) LRTrackpadStop();
    return result;
}

LRTrackpadStatistics LRTrackpadGetStatistics(void) {
    pthread_mutex_lock(&lock);
    LRTrackpadStatistics result = {frames, taps, (onTap || onPinch) ? slotCount : 0};
    pthread_mutex_unlock(&lock);
    return result;
}
