#include "TrackpadInput.h"
#include <math.h>
#include <string.h>

void LRTapReset(LRTapRecognizer *r) {
    memset(r, 0, sizeof(*r));
    r->lastTap = -1;
}

static bool reject(LRTapRecognizer *r) { r->blocked = true; return false; }

static bool processFrame(LRTapRecognizer *r, const LRContact *contacts, int count, double time) {
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
    if (activeCount > 4) return reject(r);
    // Even rejected gestures must observe their end before another can begin.
    if (!activeCount && (!r->tracking || r->blocked)) {
        double lastTap = r->lastTap;
        LRTapReset(r);
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
    if (time - r->began > .30) return reject(r);
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
            if (r->releasing || r->count == 4 || time - r->began > .09) return reject(r);
            r->origins[r->count++] = *c;
        }
        if (seen & (1u << slot)) return reject(r);
        seen |= 1u << slot;
        float dx = c->x - r->origins[slot].x, dy = c->y - r->origins[slot].y;
        if (dx * dx + dy * dy > .025f * .025f) return reject(r);
        if (active) {
            if (r->releasing && !(r->previousMask & (1u << slot))) return reject(r);
            mask |= 1u << slot;
        }
    }
    if (mask == 15 && !r->hadFour) { r->hadFour = true; r->fourAt = time; }
    if (r->previousMask & ~mask) {
        if (!r->hadFour) return reject(r);
        if (!r->releasing) {
            if (time - r->fourAt < .02) return reject(r);
            r->releasing = true;
            r->releasedAt = time;
        }
    }
    r->previousMask = mask;
    if (!r->hadFour && time - r->began > .09) return reject(r);
    if (r->releasing && time - r->releasedAt > .10) return reject(r);
    if (!activeCount) {
        bool fire = r->hadFour && time - r->began >= .03;
        double lastTap = fire ? time : r->lastTap;
        LRTapReset(r);
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
        LRTapReset(r);
        r->armed = true;
        r->lastFrame = time;
        r->lastTap = lastTap;
    }
    return fired;
}
