#include "TrackpadInput.h"
#include <math.h>
#include <string.h>


void LRTapResetForFingerCount(LRTapRecognizer *r, unsigned fingers) {
    memset(r, 0, sizeof(*r));
    r->lastTap = -1;
    r->targetCount = fingers == 3 || fingers == 4 ? fingers : 0;
}

static bool reject(LRTapRecognizer *r) { r->blocked = true; return false; }

static bool processFrame(LRTapRecognizer *r, const LRContact *contacts, int count, double time) {
    if (!r->targetCount) return reject(r);
    // Three-finger taps naturally land/lift less synchronously than four-finger
    // taps. Give them a wider timing envelope without accepting a drag/pinch.
    const double assembly = r->targetCount == 3 ? .15 : .09;
    const double duration = r->targetCount == 3 ? .42 : .30;
    const double release = r->targetCount == 3 ? .16 : .10;
    const double overlap = r->targetCount == 3 ? .012 : .02;
    const float movement = r->targetCount == 3 ? .035f : .025f;
    if (!isfinite(time) || time < 0 || count < 0 || count > 16 || (count && !contacts))
        return reject(r);
    if (time < r->lastFrame || (r->tracking && time - r->lastFrame > .12)) {
        // A missing/reordered frame could hide a swipe or a different gesture.
        r->blocked = true;
    }
    r->lastFrame = time;
    unsigned activeCount = 0;
    for (int i = 0; i < count; ++i) {
        if (contacts[i].state < 0 || contacts[i].state > 7) return reject(r);
        if (contacts[i].state == 3 || contacts[i].state == 4) ++activeCount;
    }
    if (activeCount > r->targetCount) return reject(r);
    // Even rejected gestures must observe their end before another can begin.
    if (!activeCount && (!r->tracking || r->blocked)) {
        double lastTap = r->lastTap;
        LRTapResetForFingerCount(r, r->targetCount);
        r->lastTap = lastTap;
        r->lastFrame = time;
        r->armed = true;
        return false;
    }
    if (!r->armed || r->blocked) return false;
    if (!r->tracking) {
        if (!activeCount) return false;
        if (r->lastTap >= 0 && time - r->lastTap < .35) return reject(r);
        r->tracking = true;
        r->began = time;
    }
    if (time - r->began > duration) return reject(r);
    unsigned mask = 0, seen = 0;
    for (int i = 0; i < count; ++i) {
        const LRContact *c = &contacts[i];
        bool active = c->state == 3 || c->state == 4;
        if (!active && c->state < 5) continue;
        if (!isfinite(c->x) || !isfinite(c->y) || c->x < 0 || c->x > 1 || c->y < 0 || c->y > 1)
            return reject(r);
        unsigned slot = 0;
        while (slot < r->count && r->origins[slot].id != c->id) ++slot;
        if (slot == r->count) {
            if (!active) continue;
            if (r->releasing || r->count == r->targetCount || time - r->began > assembly) return reject(r);
            r->origins[r->count++] = *c;
        }
        if (seen & (1u << slot)) return reject(r);
        seen |= 1u << slot;
        float dx = c->x - r->origins[slot].x, dy = c->y - r->origins[slot].y;
        if (dx * dx + dy * dy > movement * movement) return reject(r);
        if (active) {
            if (r->releasing && !(r->previousMask & (1u << slot))) return reject(r);
            mask |= 1u << slot;
        }
    }
    if (mask == (1u << r->targetCount) - 1 && !r->matched) { r->matched = true; r->matchedAt = time; }
    if (r->previousMask & ~mask) {
        if (!r->matched) return reject(r);
        if (!r->releasing) {
            if (time - r->matchedAt < overlap) return reject(r);
            r->releasing = true;
            r->releasedAt = time;
        }
    }
    r->previousMask = mask;
    if (!r->matched && time - r->began > assembly) return reject(r);
    if (r->releasing && time - r->releasedAt > release) return reject(r);
    if (!activeCount) {
        bool fire = r->matched && time - r->began >= .03;
        double lastTap = fire ? time : r->lastTap;
        LRTapResetForFingerCount(r, r->targetCount);
        r->armed = true;
        r->lastFrame = time;
        r->lastTap = lastTap;
        return fire;
    }
    return false;
}

bool LRTapFrame(LRTapRecognizer *r, const LRContact *contacts, int count, double time) {
    bool fired = processFrame(r, contacts, count, time);
    // Rejection may happen while processing the final release frame itself
    // (e.g. a normal one-finger tap). Re-arm on that same all-up frame; devices
    // need not send another empty frame before the next gesture.
    if (r->blocked && isfinite(time) && time >= 0 && count >= 0 && count <= 16 && (!count || contacts)) {
        for (int i = 0; i < count; ++i)
            if (contacts[i].state < 0 || contacts[i].state > 7 || contacts[i].state == 3 || contacts[i].state == 4) return fired;
        double lastTap = r->lastTap;
        LRTapResetForFingerCount(r, r->targetCount);
        r->armed = true;
        r->lastFrame = time;
        r->lastTap = lastTap;
    }
    return fired;
}
