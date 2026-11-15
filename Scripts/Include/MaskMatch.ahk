; Shape-based needle matching.
; A mask needle is a silhouette PNG (opaque pixels = the shape). The screen
; region is classified per pixel ("does this look like the glyph's outline
; color?") and every candidate position is scored hits/total. No absolute
; color is ever compared, so shade shifts and edge anti-aliasing between
; screens stop mattering; only the shape has to be there.

MM_IsNavy(argb) {
    b := argb & 0xFF, g := (argb >> 8) & 0xFF, r := (argb >> 16) & 0xFF
    return (r < 160) && (b - r > 12) && (g - r > 4)
}

; saturated yellow (energy bolt) - second discriminant class
MM_IsYellow(argb) {
    b := argb & 0xFF, g := (argb >> 8) & 0xFF, r := (argb >> 16) & 0xFF
    return (r > 200) && (g > 170) && (b < 150)
}

; 0 = other, 1 = navy, 2 = yellow
MM_PixelClass(argb) {
    if (MM_IsNavy(argb))
        return 1
    if (MM_IsYellow(argb))
        return 2
    return 0
}

; Loads a two-state mask PNG into {w,h,navy,yellow,other,total}. The lists are
; packed offsets (y<<8|x): opaque dark pixels must land on navy screen pixels,
; opaque red-dominant ones on yellow, opaque bright ones on pixels that are
; neither (the "other" class). Transparent pixels are ignored.
; spec may carry a rotation suffix "file.png@90|180|270" (clockwise degrees):
; the game reuses the same hand sprite rotated, so one PNG covers every
; orientation instead of storing a file per rotation.
MM_LoadMask(spec) {
    static cache := {}
    if (cache.HasKey(spec))
        return cache[spec]
    file := spec, rot := 0
    if (p := InStr(spec, "@")) {
        file := SubStr(spec, 1, p - 1)
        rot := Mod(SubStr(spec, p + 1) + 0, 360)
    }
    pB := Gdip_CreateBitmapFromFile(file)
    navy := [], yellow := [], other := []
    Gdip_GetImageDimensions(pB, w, h)
    if (pB && w && h && !Gdip_LockBits(pB, 0, 0, w, h, stride, scan, data, 1)) {
        Loop, % h {
            yy := A_Index - 1
            Loop, % w {
                xx := A_Index - 1
                argb := NumGet(scan + 0, yy * stride + xx * 4, "UInt")
                if (!((argb >> 24) & 0xFF))
                    continue
                if (rot = 90) {
                    rx := h - 1 - yy, ry := xx
                } else if (rot = 180) {
                    rx := w - 1 - xx, ry := h - 1 - yy
                } else if (rot = 270) {
                    rx := yy, ry := w - 1 - xx
                } else {
                    rx := xx, ry := yy
                }
                r := (argb >> 16) & 0xFF, g := (argb >> 8) & 0xFF
                ; red-dominant pixels mark the yellow class; dark ones navy;
                ; bright neutral ones "other" (must not be navy nor yellow)
                if (r > 150 && g < 120)
                    yellow.Push(ry * 256 + rx)
                else if (r < 128)
                    navy.Push(ry * 256 + rx)
                else
                    other.Push(ry * 256 + rx)
            }
        }
        Gdip_UnlockBits(pB, data)
    }
    if (pB)
        Gdip_DisposeImage(pB)
    if (rot = 90 || rot = 270)
        mw := h, mh := w
    else
        mw := w, mh := h
    cache[spec] := {w: mw, h: mh, navy: navy, yellow: yellow, other: other, total: navy.Length() + yellow.Length() + other.Length()}
    return cache[spec]
}

; Slides the mask over region [x1,y1,x2,y2) of pBitmap. Returns
; [x, y, score] for the best position found (score = hits/total), or 0
; when the region cannot hold the mask. Caller decides the threshold.
MM_MaskSearch(pBitmap, mask, x1, y1, x2, y2) {
    rw := x2 - x1, rh := y2 - y1
    if (rw < mask.w || rh < mask.h || mask.total = 0)
        return 0
    if (Gdip_LockBits(pBitmap, x1, y1, rw, rh, stride, scan, data, 1))
        return 0
    cls := []
    cls.SetCapacity(rw * rh + 1)
    Loop, % rh {
        row := (A_Index - 1) * stride
        base := (A_Index - 1) * rw
        Loop, % rw {
            cls[base + A_Index] := MM_PixelClass(NumGet(scan + 0, row + (A_Index - 1) * 4, "UInt"))
        }
    }
    Gdip_UnlockBits(pBitmap, data)

    total := mask.total
    bestHits := 0, bestX := -1, bestY := -1
    Loop, % rh - mask.h + 1 {
        oy := A_Index - 1
        Loop, % rw - mask.w + 1 {
            ox := A_Index - 1
            ; a position dies when its misses can no longer let it beat best,
            ; or when they pass 25% of the mask - that low is a miss anyway
            hits := 0, misses := 0, budget := total - bestHits, pos := oy * rw + ox
            cap := Floor(total * 0.25)
            if (cap < budget)
                budget := cap
            for i, off in mask.navy {
                if (cls[pos + (off >> 8) * rw + (off & 255)] = 1)
                    hits++
                else if (++misses > budget)
                    break
            }
            if (misses <= budget) {
                for i, off in mask.yellow {
                    if (cls[pos + (off >> 8) * rw + (off & 255)] = 2)
                        hits++
                    else if (++misses > budget)
                        break
                }
            }
            if (misses <= budget) {
                for i, off in mask.other {
                    if (cls[pos + (off >> 8) * rw + (off & 255)] = 0)
                        hits++
                    else if (++misses > budget)
                        break
                }
            }
            if (hits > bestHits) {
                bestHits := hits, bestX := ox, bestY := oy
                if (hits = total)
                    return [x1 + ox, y1 + oy, 1.0]
            }
        }
    }
    if (bestX >= 0)
        return [x1 + bestX, y1 + bestY, bestHits / total]
    return 0
}
