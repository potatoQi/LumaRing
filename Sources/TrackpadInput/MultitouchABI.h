// Private ABI declarations adapted from OpenMultitouchSupport's OpenMTInternal.h.
// Copyright (c) 2019 TakutoNakamura. MIT; see THIRD_PARTY_NOTICES.md.
// Reference revision: 15c6bb0c6a2d2858559493a28ab23f7ac58648a3.
// Only the contact layout and function types are retained, with fixed-width
// integer fields and dynamic symbol resolution. No upstream runtime is bundled.
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stddef.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier, state, fingerID, handID;
    MTVector normalizedPosition;
    float total, pressure, angle, majorAxis, minorAxis;
    MTVector absolutePosition;
    int32_t field14, field15;
    float density;
} MTTouch;
_Static_assert(sizeof(MTTouch) == 96, "Unexpected multitouch ABI size");
_Static_assert(offsetof(MTTouch, normalizedPosition) == 32, "Unexpected multitouch ABI offset");
typedef void *MTDeviceRef;
typedef void (*MTFrameCallback)(MTDeviceRef, MTTouch *, int, double, int);
