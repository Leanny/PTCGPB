/* Native mask scan used by MaskMatch.ahk. Same class rules and the same
   off-by-one lookup as the AHK scan, so a score from here matches one
   from MM_MaskSearchAhk. */
#include <stdint.h>
#include <stdlib.h>

__declspec(dllexport)
int MM_Search(
    const uint8_t* scan, int stride,
    int rw, int rh,
    const uint16_t* navy, int navyN,
    const uint16_t* yellow, int yellowN,
    const uint16_t* other, int otherN,
    int mw, int mh,
    int minHits,
    int* outX, int* outY, int* outHits)
{
    int total = navyN + yellowN + otherN;
    if (!scan || rw < mw || rh < mh || total <= 0 || mw <= 0 || mh <= 0)
        return 0;

    uint8_t* cls = (uint8_t*)malloc((size_t)rw * (size_t)rh);
    int iw = rw + 1;
    int* integ = (int*)calloc((size_t)iw * (size_t)(rh + 1), sizeof(int));
    if (!cls || !integ) {
        free(cls);
        free(integ);
        return 0;
    }

    for (int yy = 0; yy < rh; yy++) {
        const uint8_t* row = scan + (size_t)yy * stride;
        int sum = 0;
        for (int xx = 0; xx < rw; xx++) {
            uint32_t argb = *(const uint32_t*)(row + xx * 4);
            int b = (int)(argb & 255);
            int g = (int)((argb >> 8) & 255);
            int r = (int)((argb >> 16) & 255);
            int class = 0;
            if (r < 160 && (b - r) > 12 && (g - r) > 4)
                class = 1;
            else if (r > 200 && g > 170 && b < 150)
                class = 2;
            cls[(size_t)yy * rw + xx] = (uint8_t)class;
            if (class == 1)
                sum++;
            integ[(yy + 1) * iw + (xx + 1)] = integ[yy * iw + (xx + 1)] + sum;
        }
    }

    int bestHits = minHits > 0 ? minHits - 1 : 0;
    int bestX = -1, bestY = -1;
    int found = 0;

    for (int oy = 0; oy <= rh - mh && !found; oy++) {
        for (int ox = 0; ox <= rw - mw; ox++) {
            int budget = total - bestHits;
            int cap = total / 4;
            if (minHits > 0 && total - minHits < cap)
                cap = total - minHits;
            if (cap < budget)
                budget = cap;
            if (minHits > 0) {
                int x2 = ox + mw, y2 = oy + mh;
                int nRect = integ[y2 * iw + x2] - integ[oy * iw + x2]
                    - integ[y2 * iw + ox] + integ[oy * iw + ox];
                int needNavy = navyN - budget - mh;
                if (needNavy > 0 && nRect < needNavy)
                    continue;
            }

            int hits = 0, misses = 0, stop = 0;
            int pos = oy * rw + ox;
            for (int i = 0; i < navyN; i++) {
                int off = navy[i];
                int idx = pos + (off >> 8) * rw + (off & 255);
                int class = (idx >= 1) ? cls[idx - 1] : 0;
                if (class == 1)
                    hits++;
                else if (++misses > budget) {
                    stop = 1;
                    break;
                }
            }
            if (!stop) {
                for (int i = 0; i < yellowN; i++) {
                    int off = yellow[i];
                    int idx = pos + (off >> 8) * rw + (off & 255);
                    int class = (idx >= 1) ? cls[idx - 1] : 0;
                    if (class == 2)
                        hits++;
                    else if (++misses > budget) {
                        stop = 1;
                        break;
                    }
                }
            }
            if (!stop) {
                for (int i = 0; i < otherN; i++) {
                    int off = other[i];
                    int idx = pos + (off >> 8) * rw + (off & 255);
                    int class = (idx >= 1) ? cls[idx - 1] : 0;
                    if (class == 0)
                        hits++;
                    else if (++misses > budget) {
                        stop = 1;
                        break;
                    }
                }
            }
            if (hits > bestHits) {
                bestHits = hits;
                bestX = ox;
                bestY = oy;
                if ((minHits > 0 && hits >= minHits) || hits == total) {
                    found = 1;
                    break;
                }
            }
        }
    }
    if (!found && bestX >= 0 && (minHits <= 0 || bestHits >= minHits))
        found = 1;
    if (found) {
        *outX = bestX;
        *outY = bestY;
        *outHits = bestHits;
    }
    free(cls);
    free(integ);
    return found;
}
