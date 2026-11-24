;===============================================================================
; CardLoading.ahk - Detect when the cards on the pack result screen have settled
;===============================================================================
; Every settled card shows its (non-shadow coloured) bottom edge at the slot
; row and a soft blue shadow 3px below it. The lag*.png needles are a sample of
; that shadow. A slot counts as "loaded" when:
;   - the edge strip does NOT look like the shadow (a card border is there), and
;   - the strip 3px below DOES look like the shadow (the card sits exactly here).
; Plain background is ~37-40 away from the needle, so it fails the shadow check
; and an empty slot never counts as a card.
;===============================================================================

global CardLoading_NeedleDir

;-------------------------------------------------------------------------------
; CardLoading_Layouts - Slot coordinates [x, y] of the card bottom edge for each
; card count. Each slot is a 20x2 strip starting at (x, y).
;-------------------------------------------------------------------------------
CardLoading_Layouts() {
    static layouts := ""
    if (IsObject(layouts))
        return layouts

    layouts := {}
    ; Single row (1-3 cards), bottom edge at y~337
    layouts[1] := [[139, 337]]
    layouts[2] := [[96, 337], [181, 337]]
    layouts[3] := [[56, 337], [139, 337], [222, 337]]
    ; Two rows, bottom edges at y~279 and y~394
    layouts[4] := [[96, 279], [181, 279]
        , [96, 394], [181, 394]]
    layouts[5] := [[56, 279], [139, 279], [222, 279]
        , [96, 394], [181, 394]]
    layouts[6] := [[56, 279], [139, 279], [222, 279]
        , [56, 394], [139, 394], [222, 394]]
    return layouts
}

;-------------------------------------------------------------------------------
; CardLoading_SlotLoaded - True if a settled card bottom edge is at (x, y)
;-------------------------------------------------------------------------------
CardLoading_SlotLoaded(pBitmap, pNeedle, x, y) {
    static EDGE_VARIATION := 40   ; edge must differ from the shadow by more than this
    static SHADOW_VARIATION := 25 ; settled shadows measure <= 16, plain background 37-40
    static SHADOW_OFFSET := 3     ; rows between the edge row and the shadow row

    edge := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, x, y, x + 20, y + 2, EDGE_VARIATION)
    if (edge = 1)
        return false
    sy := y + SHADOW_OFFSET
    shadow := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, x, sy, x + 20, sy + 2, SHADOW_VARIATION)
    return (shadow = 1)
}

;-------------------------------------------------------------------------------
; CardLoading_ScoreLayout - Number of loaded slots for a card count layout
;-------------------------------------------------------------------------------
CardLoading_ScoreLayout(pBitmap, cardCount) {
    layout := CardLoading_Layouts()[cardCount]
    if (!IsObject(layout))
        return 0

    needleDir := (CardLoading_NeedleDir != "") ? CardLoading_NeedleDir : A_ScriptDir . "\Needles"
    score := 0
    for index, slot in layout {
        Path := needleDir . "\lag" . index . ".png"
        if (!FileExist(Path))
            continue
        if (CardLoading_SlotLoaded(pBitmap, GetNeedle(Path), slot[1], slot[2]))
            score += 1
    }
    return score
}

;-------------------------------------------------------------------------------
; CardLoading_FindLoadedLayout - Card count of the largest fully loaded layout,
; or 0 if none is. Largest first because smaller layouts can be a subset of a
; larger one (the 1-card slot is also the middle slot of the 3-card layout).
;-------------------------------------------------------------------------------
CardLoading_FindLoadedLayout(pBitmap) {
    layouts := CardLoading_Layouts()
    Loop, 6 {
        count := 7 - A_Index
        if (CardLoading_ScoreLayout(pBitmap, count) = layouts[count].MaxIndex())
            return count
    }
    return 0
}
