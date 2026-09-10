#include "TrackpadInput.h"
#include <math.h>
#include <string.h>

void LRPinchReset(LRPinchRecognizer *r) {
    memset(r, 0, sizeof(*r));
    r->lastPinch = -1;
    r->bestRatio = 1;
}

static float distance(LRContact a, LRContact b) {
    return hypotf(a.x - b.x, a.y - b.y);
}

static LRPinchEvent reject(LRPinchRecognizer *r) {
    bool notify = r->announced && !r->blocked;
    r->blocked = true;
    return notify ? LRPinchCancelled : LRPinchNone;
}

static LRPinchEvent process(LRPinchRecognizer *r, const LRContact *c, int count, double time) {
    if (!isfinite(time) || time < 0 || count < 0 || count > 16 || (count && !c)) return reject(r);
    if (time < r->lastFrame || (r->tracking && time - r->lastFrame > .15)) return reject(r);
    r->lastFrame = time;
    unsigned active = 0;
    for (int i = 0; i < count; ++i) {
        if (c[i].state < 0 || c[i].state > 7 || !isfinite(c[i].x) || !isfinite(c[i].y) ||
            c[i].x < 0 || c[i].x > 1 || c[i].y < 0 || c[i].y > 1) return reject(r);
        if (c[i].state == 3 || c[i].state == 4) ++active;
        for (int j = 0; j < i; ++j) if (c[j].id == c[i].id) return reject(r);
    }
    if (active > 3) return reject(r);
    if (!r->armed || r->blocked) return LRPinchNone;
    if (!r->tracking) {
        if (!active) return LRPinchNone;
        if (r->lastPinch >= 0 && time - r->lastPinch < .45) return reject(r);
        r->tracking = true;
        r->began = time;
    }
    if (time - r->began > 1.6) return reject(r);
    unsigned mask = 0;
    LRContact current[3];
    memcpy(current, r->latest, sizeof(current));
    for (int i = 0; i < count; ++i) {
        bool down = c[i].state == 3 || c[i].state == 4;
        if (!down && c[i].state != 5) continue;
        unsigned slot = 0;
        while (slot < r->count && r->origins[slot].id != c[i].id) ++slot;
        if (slot == r->count) {
            if (!down) continue;
            if (r->announced || r->releasing || r->count == 3 || time - r->began > .18) return reject(r);
            r->origins[r->count] = r->latest[r->count] = c[i];
            ++r->count;
        }
        // Lingering/out-of-range samples can keep moving after this finger has
        // already lifted. Preserve its last release point instead of treating
        // those hover coordinates as continued touch motion.
        if (!down && r->releasing && !(r->previousMask & (1u << slot))) continue;
        if (down) {
            if (r->releasing && !(r->previousMask & (1u << slot))) return reject(r);
            mask |= 1u << slot;
        }
        if (!r->announced && distance(c[i], r->origins[slot]) > .035f) return reject(r);
        current[slot] = c[i];
    }
    if (!r->announced) {
        if ((r->previousMask & ~mask) || time - r->began > .18) return reject(r);
        r->previousMask = mask;
        if (mask != 7) return LRPinchNone;
        float spread = 0;
        for (int i = 0; i < 3; ++i) for (int j = i + 1; j < 3; ++j) {
            float d = distance(current[i], current[j]);
            if (d < .025f) return reject(r);
            spread += d;
        }
        if (spread / 3 < .09f) return reject(r);
        memcpy(r->origins, current, sizeof(current));
        memcpy(r->latest, current, sizeof(current));
        r->announced = true;
        return LRPinchBegan;
    }
    // The first lift confirmed the pinch. Only wait for the same fingers to
    // lift now; ownership, returning-finger and input checks still run above.
    if (r->releasing) {
        if (time - r->releasedAt > .22) return reject(r);
        r->previousMask = mask;
        if (!active) { r->lastPinch = time; return LRPinchCompleted; }
        return LRPinchNone;
    }
    // Evaluate touch and initial break-touch coordinates through the first lift.
    // Later hover states never contribute to contraction.
    // Natural pinches are asymmetric: two fingers may keep their spacing.
    // Require overall contraction, two shrinking pairs and two inward-moving
    // fingers so translation, rotation and a lone moving finger still fail.
    float dx = 0, dy = 0, totalBefore = 0, totalNow = 0, largestRatio = 0;
    float centerX = 0, centerY = 0;
    unsigned shrinkingPairs = 0, inwardFingers = 0;
    for (int i = 0; i < 3; ++i) { centerX += r->origins[i].x / 3; centerY += r->origins[i].y / 3; }
    for (int i = 0; i < 3; ++i) {
        dx += current[i].x - r->origins[i].x;
        dy += current[i].y - r->origins[i].y;
        float rx = centerX - r->origins[i].x, ry = centerY - r->origins[i].y;
        float radius = hypotf(rx, ry);
        if (radius > .01f && ((current[i].x - r->origins[i].x) * rx +
            (current[i].y - r->origins[i].y) * ry) / radius >= .04f) ++inwardFingers;
        for (int j = i + 1; j < 3; ++j) {
            float before = distance(r->origins[i], r->origins[j]);
            float now = distance(current[i], current[j]);
            largestRatio = fmaxf(largestRatio, now / before);
            if (now / before <= .88f) ++shrinkingPairs;
            totalBefore += before; totalNow += now;
        }
    }
    float ratio = totalNow / totalBefore;
    // An asymmetric pinch naturally shifts its centroid. Allow drift in
    // proportion to actual contraction; translation alone gets no extra room.
    float contraction = (totalBefore - totalNow) / 3;
    if (hypotf(dx / 3, dy / 3) > fmaxf(.08f, contraction * .6f) || largestRatio > 1.20f ||
        (r->qualified && ratio > r->bestRatio + .14f)) return reject(r);
    // Include the first break-touch frame: a quick pinch can cross the
    // contraction threshold in the final contact sample before lift.
    if (!r->releasing) {
        r->bestRatio = fminf(r->bestRatio, ratio);
        r->qualified = ratio <= .88f && largestRatio <= 1.10f && shrinkingPairs >= 2 && inwardFingers >= 2 &&
            contraction >= .025f;
        memcpy(r->latest, current, sizeof(current));
    }
    if (r->previousMask & ~mask) {
        if (!r->qualified || ratio > .92f || time - r->began < .06) return reject(r);
        if (!r->releasing) { r->releasing = true; r->releasedAt = time; }
    }
    // Preserve the final geometry at confirmation; later lift frames only
    // update contact ownership in the releasing branch above.
    memcpy(r->latest, current, sizeof(current));
    r->previousMask = mask;
    if (r->releasing && time - r->releasedAt > .22) return reject(r);
    if (!active) {
        if (!r->qualified) return reject(r);
        r->lastPinch = time;
        return LRPinchCompleted;
    }
    return LRPinchNone;
}

LRPinchEvent LRPinchFrame(LRPinchRecognizer *r, const LRContact *c, int count, double time) {
    LRPinchEvent event = process(r, c, count, time);
    // A final release frame is sufficient to re-arm; no idle polling is needed.
    if (isfinite(time) && time >= 0 && count >= 0 && count <= 16 && (!count || c)) {
        for (int i = 0; i < count; ++i)
            if (c[i].state < 0 || c[i].state > 7 || c[i].state == 3 || c[i].state == 4) return event;
        double lastPinch = r->lastPinch;
        LRPinchReset(r);
        r->armed = true; r->lastFrame = time; r->lastPinch = lastPinch;
    }
    return event;
}
