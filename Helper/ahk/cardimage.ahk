;===============================================================================
; cardimage.ahk - AutoHotkey v1 fallback for Helper\cardimage.exe
;===============================================================================
; Command-line compatible port of cardimage.exe (Discord pack image):
;
;   AutoHotkey.exe cardimage.ahk <input> <output> [--cols N]
;       [--cardmaster cardmap.json] [--cache-dir CardImageCache]
;       [--highlight id1,id2]
;
; Same layout, colors, wishlist heart badge, image cache folder and
; cardmap.json refresh rules as the Rust version. Drawing uses GDI+
; (Scripts\Include\Gdip_All.ahk) and the font bundled with the Rust sources.
; Relative paths resolve against the working directory (the bot runs it from
; Helper\), like the exe.
;===============================================================================

#NoEnv
#NoTrayIcon
#SingleInstance Off
SetBatchLines, -1
ListLines, Off
FileEncoding, UTF-8-RAW
OnError("CardImage_OnUnhandledError")

#Include %A_ScriptDir%\lib\Json.ahk
#Include %A_ScriptDir%\lib\Common.ahk
#Include %A_ScriptDir%\..\..\Scripts\Include\Gdip_All.ahk

global CI_CARD_W := 200, CI_CARD_H := 280, CI_PADDING := 10, CI_BASE_COLS := 6
global CI_BG := 0xFF1A1A2E, CI_PH_FILL := 0xFF252545, CI_PH_BORDER := 0xFF4A4A9E, CI_TEXT := 0xFFAAAAAA
global CI_BADGE_BG := 0xFFE8254F, CI_BADGE_RIM := 0xFFFFC8D2, CI_HEART := 0xFFFFFFFF
global CI_BADGE_RADIUS_BASE := 22.0, CI_HEART_RADIUS_BASE := 14.0, CI_BADGE_OFFSET_BASE := 26.0
global CI_U32_MAX := 4294967295

try {
    code := CardImage_Main()
} catch e {
    StdErr("Error: " . e.Message)
    ExitApp, 1
}
ExitApp, %code%

CardImage_OnUnhandledError(e) {
    StdErr("Error: " . (IsObject(e) ? e.Message . " (line " . e.Line . ")" : e))
    ExitApp, 1
}

CardImage_Main() {
    args := []
    for _, arg in A_Args
        args.Push(arg)
    try {
        cli := Cli_Parse(args, 1, {values: "cols cardmaster cache-dir highlight", flags: ""})
        if (cli.pos.Length() < 2)
            throw Exception("the following required arguments were not provided: <INPUT> <OUTPUT>")
        if (cli.pos.Length() > 2)
            throw Exception("unexpected argument '" . cli.pos[3] . "' found")
        cols := cli.opts.HasKey("cols") ? cli.opts.cols : "6"
        if (!RegExMatch(cols, "^\+?\d{1,9}$"))
            throw Exception("invalid value '" . cols . "' for '--cols <COLS>': invalid digit found in string")
    } catch e {
        StdErr("error: " . e.Message)
        return 2
    }

    input := Path_Full(cli.pos[1])
    output := Path_Full(cli.pos[2])
    cardmapPath := Path_Full(cli.opts.HasKey("cardmaster") ? cli.opts.cardmaster : "cardmap.json")
    cacheDir := Path_Full(cli.opts.HasKey("cache_dir") ? cli.opts.cache_dir : "CardImageCache")
    highlight := new JObj
    for _, id in StrSplit(cli.opts.HasKey("highlight") ? cli.opts.highlight : "", ",") {
        id := S_Trim(id)
        if (id != "")
            highlight.Set(id, true)
    }

    raw := File_ReadUtf8(input)
    cardIds := CI_ParseIds(raw)
    if (!cardIds.Length()) {
        StdErr("No card IDs found in """ . StrReplace(input, "\", "\\") . """")
        return 1
    }

    entries := CI_LoadCardmapWithRefresh(cardmapPath, cardIds)
    Dir_Create(cacheDir)

    baseUrl := "https://leanny.github.io/pocket_tcg_resources/img/M/US"
    cachedPaths := []
    toDownload := []
    for _, cid in cardIds {
        entry := entries.Get(cid)
        if (IsObject(entry) && entry.ill != "") {
            safe := RegExReplace(entry.ill, "[\\/:<>""*?|]", "_")
            dest := cacheDir . "\" . safe . ".png"
            if (!File_Exists(dest) || File_Size(dest) <= 1000)
                toDownload.Push({url: baseUrl . "/" . entry.ill . ".png", dest: dest})
            cachedPaths.Push(dest)
        } else {
            cachedPaths.Push("")
        }
    }

    failed := 0
    for _, ok in CI_DownloadAll(toDownload, 20)
        if (!ok)
            failed += 1
    if (failed)
        StdErr(failed . " image(s) failed to download (shown as placeholders)")

    pToken := Gdip_Startup()
    if (!pToken)
        throw Exception("GDI+ could not be started")
    try {
        cards := []
        for i, cid in cardIds {
            path := cachedPaths[i]
            pBitmap := 0
            if (path != "" && File_Exists(path) && File_Size(path) > 1000) {
                if (DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", path, "Ptr*", pBitmap) != 0)
                    pBitmap := 0
            }
            key := CI_CardSortKey(cid, entries)
            cards.Push({id: cid, bitmap: pBitmap, exp: key.exp, num: key.num})
        }
        Arr_Sort(cards, Func("CI_CompareCards"))

        pCanvas := CI_Composite(cards, cols + 0, highlight)
        Dir_Create(Path_Dir(output))
        result := Gdip_SaveBitmapToFile(pCanvas, output)
        Gdip_DisposeImage(pCanvas)
        for _, card in cards
            if (card.bitmap)
                Gdip_DisposeImage(card.bitmap)
        if (result != 0)
            throw Exception("Could not save image to """ . output . """ (" . result . ")")
    } finally {
        Gdip_Shutdown(pToken)
    }
    return 0
}

CI_ParseIds(ByRef text) {
    ids := []
    Loop, Parse, text, `n
    {
        for _, part in StrSplit(RTrim(A_LoopField, "`r"), ",") {
            part := S_Trim(part)
            if (part != "")
                ids.Push(part)
        }
    }
    return ids
}

;-------------------------------------------------------------------------------
; cardmap.json
;-------------------------------------------------------------------------------

; Returns JObj cardId -> {ill, exp, num} for the requested ids that exist.
CI_LookupEntries(ByRef text, cardIds) {
    entries := new JObj
    for _, cid in cardIds {
        if (entries.Has(cid))
            continue
        body := CardMap_EntryBody(text, cid)
        if (body = "" && !RegExMatch(text, "S)""\Q" . cid . "\E""\s*:\s*\{\s*\}"))
            continue
        num := CardMap_BodyInt(body, "CollectionNumber")
        if (num = "" || num < 0 || num > CI_U32_MAX)
            num := CI_U32_MAX
        entries.Set(cid, {ill: CardMap_BodyStr(body, "IllustrationID")
            , exp: CardMap_BodyStr(body, "ExpansionID"), num: num})
    }
    return entries
}

CI_ReadCardmapText(path) {
    text := File_ReadUtf8(path)
    if (!RegExMatch(text, "^\s*\{") || !RegExMatch(text, "\}\s*$"))
        throw Exception("Could not parse cardmap JSON at """ . path . """")
    return text
}

CI_LoadCardmapWithRefresh(path, cardIds) {
    if (!File_Exists(path))
        CardMap_Download(path, false)
    text := CI_ReadCardmapText(path)
    entries := CI_LookupEntries(text, cardIds)
    missing := false
    for _, cid in cardIds
        if (!entries.Has(cid))
            missing := true
    if (missing && !CardMap_IsFresh(path)) {
        CardMap_Download(path, true)
        text := CI_ReadCardmapText(path)
        entries := CI_LookupEntries(text, cardIds)
    }
    return entries
}

; (ExpansionID, CollectionNumber); unknown cards derive the number from the id.
CI_CardSortKey(cid, entries) {
    entry := entries.Get(cid)
    if (IsObject(entry))
        return {exp: entry.exp, num: entry.num}
    parts := StrSplit(cid, "_")
    num := CI_U32_MAX
    if (parts.Length() >= 3 && RegExMatch(parts[3], "^\+?\d{1,10}$") && parts[3] + 0 <= CI_U32_MAX)
        num := (parts[3] + 0) // 10
    return {exp: "", num: num}
}

CI_CompareCards(a, b) {
    c := S_Cmp(a.exp, b.exp)
    if (c)
        return c
    return (a.num < b.num) ? -1 : (a.num > b.num) ? 1 : 0
}

;-------------------------------------------------------------------------------
; Downloads (up to maxConn parallel requests, like the Rust chunks)
;-------------------------------------------------------------------------------

CI_DownloadAll(tasks, maxConn) {
    results := []
    i := 1
    n := tasks.Length()
    while (i <= n) {
        batch := []
        while (i <= n && batch.Length() < maxConn) {
            task := tasks[i]
            i += 1
            entry := {task: task, req: "", done: false, ok: false}
            if (File_Exists(task.dest) && File_Size(task.dest) > 1000) {
                entry.done := true, entry.ok := true
            } else {
                File_Delete(task.dest)
                try {
                    req := Http_NewRequest()
                    req.Open("GET", task.url, true)
                    req.Send()
                    entry.req := req
                } catch {
                    entry.done := true
                }
            }
            batch.Push(entry)
        }
        for _, entry in batch {
            if (!entry.done) {
                try {
                    if (entry.req.WaitForResponse(60) && entry.req.Status >= 200 && entry.req.Status < 300)
                        entry.ok := Http_SaveBody(entry.req.ResponseBody, entry.task.dest, 1001)
                }
            }
            results.Push(entry.ok)
        }
    }
    return results
}

;-------------------------------------------------------------------------------
; Layout and drawing
;-------------------------------------------------------------------------------

CI_DivCeil(a, b) {
    return (a + b - 1) // b
}

; Column count that makes cards largest after Discord scales the square preview.
CI_PickDynamicCols(total) {
    baseW := CI_PADDING + CI_BASE_COLS * (CI_CARD_W + CI_PADDING)
    maxSide := (baseW * 7) // 5
    bestCols := Max(Min(CI_BASE_COLS, total), 1)
    bestNum := 0, bestDen := 1
    c := 2
    while (c <= total) {
        cardW := Max(baseW - (c + 1) * CI_PADDING, 0) // c
        if (cardW > 0) {
            cardH := (cardW * CI_CARD_H) // CI_CARD_W
            rows := CI_DivCeil(total, c)
            gridH := (rows + 1) * CI_PADDING + rows * cardH
            side := Max(baseW, gridH)
            if (side <= maxSide && cardW * bestDen > bestNum * side) {
                bestCols := c
                bestNum := cardW
                bestDen := side
            }
        }
        c += 1
    }
    return bestCols
}

CI_Composite(cards, maxCols, highlight) {
    total := cards.Length()
    if (maxCols = 6)
        maxCols := (total <= 6) ? 3 : CI_PickDynamicCols(total)
    else
        maxCols := Max(maxCols, 1)
    rows := CI_DivCeil(total, maxCols)

    gridW := CI_PADDING + CI_BASE_COLS * (CI_CARD_W + CI_PADDING)
    cardW := Max(gridW - (maxCols + 1) * CI_PADDING, 0) // maxCols
    cardH := (cardW * CI_CARD_H) // CI_CARD_W
    gridH := CI_PADDING + rows * (cardH + CI_PADDING)
    side := Max(gridW, gridH)
    padX := (side - gridW) // 2
    padY := (side - gridH) // 2

    pCanvas := Gdip_CreateBitmap(side, side)
    G := Gdip_GraphicsFromImage(pCanvas)
    Gdip_GraphicsClear(G, CI_BG)
    Gdip_SetInterpolationMode(G, 7)
    DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", G, "Int", 2)
    DllCall("gdiplus\GdipSetCompositingQuality", "Ptr", G, "Int", 2)
    DllCall("gdiplus\GdipCreateImageAttributes", "Ptr*", attr)
    DllCall("gdiplus\GdipSetImageAttributesWrapMode", "Ptr", attr, "Int", 3, "UInt", 0, "Int", 0)
    font := new CI_Font(G)

    for idx0, card in cards {
        idx := idx0 - 1
        col := Mod(idx, maxCols)
        row := idx // maxCols
        if (row = rows - 1) {
            remainder := Mod(total, maxCols)
            cardsInRow := remainder ? remainder : maxCols
        } else {
            cardsInRow := maxCols
        }
        centerOffset := ((maxCols - cardsInRow) * (cardW + CI_PADDING)) // 2
        x := padX + CI_PADDING + centerOffset + col * (cardW + CI_PADDING)
        y := padY + CI_PADDING + row * (cardH + CI_PADDING)

        if (card.bitmap) {
            w := Gdip_GetImageWidth(card.bitmap)
            h := Gdip_GetImageHeight(card.bitmap)
            DllCall("gdiplus\GdipDrawImageRectRectI", "Ptr", G, "Ptr", card.bitmap
                , "Int", x, "Int", y, "Int", cardW, "Int", cardH
                , "Int", 0, "Int", 0, "Int", w, "Int", h
                , "Int", 2, "Ptr", attr, "Ptr", 0, "Ptr", 0)
        } else {
            CI_DrawPlaceholder(G, font, card.id, x, y, cardW, cardH)
        }

        if (highlight.Has(card.id)) {
            scale := cardW / CI_CARD_W
            badgeRadius := Round(CI_BADGE_RADIUS_BASE * scale)
            heartRadius := CI_HEART_RADIUS_BASE * scale
            badgeOffset := Round(CI_BADGE_OFFSET_BASE * scale)
            cx := x + cardW - badgeOffset
            cy := y + badgeOffset
            CI_DrawBadge(G, cx, cy, badgeRadius)
            CI_DrawHeart(G, cx, cy, heartRadius, CI_HEART)
        }
    }

    font.Dispose()
    DllCall("gdiplus\GdipDisposeImageAttributes", "Ptr", attr)
    Gdip_DeleteGraphics(G)
    return pCanvas
}

CI_FillRect(G, color, x, y, w, h) {
    if (w <= 0 || h <= 0)
        return
    brush := Gdip_BrushCreateSolid(color)
    Gdip_FillRectangle(G, brush, x, y, w, h)
    Gdip_DeleteBrush(brush)
}

CI_DrawPlaceholder(G, font, cardId, x, y, w, h) {
    ; Two 1px border rings like the Rust placeholder.
    CI_FillRect(G, CI_PH_BORDER, x, y, w, h)
    CI_FillRect(G, CI_PH_FILL, x + 2, y + 2, w - 4, h - 4)

    label := SubStr(cardId, 1, 20)
    mid := StrLen(label) // 2
    split := InStr(SubStr(label, 1, mid), "_", true, 0)
    split := split ? split : mid
    lines := [SubStr(label, 1, split), SubStr(label, split + 1)]

    lineH := font.lineHeight
    totalH := lineH * 2 + 4
    yStart := Max(h - totalH, 0) // 2
    for i, line in lines
        font.DrawCentered(line, x, y + yStart + (i - 1) * (lineH + 4), w, CI_TEXT)
}

; Red circle with a light rim (wishlist badge).
CI_DrawBadge(G, cx, cy, r) {
    Gdip_SetSmoothingMode(G, 4)
    brush := Gdip_BrushCreateSolid(CI_BADGE_BG)
    Gdip_FillEllipse(G, brush, cx - r, cy - r, 2 * r + 1, 2 * r + 1)
    Gdip_DeleteBrush(brush)
    pen := Gdip_CreatePen(CI_BADGE_RIM, 1)
    Gdip_DrawEllipse(G, pen, cx - r, cy - r, 2 * r + 1, 2 * r + 1)
    Gdip_DeletePen(pen)
    Gdip_SetSmoothingMode(G, 3)
}

; Fills pixels inside (x^2 + y^2 - 1)^3 - x^2 * y^3 <= 0, scaled to radius and
; shifted like the Rust version. Each row is filled as horizontal runs.
CI_DrawHeart(G, cx, cy, radius, color) {
    brush := Gdip_BrushCreateSolid(color)
    rx := Ceil(radius * 1.3)
    ryTop := Ceil(radius * 1.1)
    ryBot := Ceil(radius * 1.4)
    dy := -ryTop
    while (dy <= ryBot) {
        runStart := ""
        dx := -rx
        while (dx <= rx + 1) {
            inside := false
            if (dx <= rx) {
                px := dx / radius
                py := -dy / radius + 0.25
                t := px * px + py * py - 1.0
                inside := (t * t * t - px * px * py * py * py) <= 0.0
            }
            if (inside && runStart = "") {
                runStart := dx
            } else if (!inside && runStart != "") {
                Gdip_FillRectangle(G, brush, cx + runStart, cy + dy, dx - runStart, 1)
                runStart := ""
            }
            dx += 1
        }
        dy += 1
    }
    Gdip_DeleteBrush(brush)
}

; The DejaVu Sans Mono font bundled with the Rust sources, at the same size as
; ab_glyph's PxScale 13 (ascent - descent = 13 px).
class CI_Font {
    __New(G) {
        this.G := G
        this.collection := 0
        this.family := 0
        fontPaths := [A_ScriptDir . "\font.ttf", A_ScriptDir . "\..\cardimage_src\src\font.ttf"]
        for _, path in fontPaths {
            if (!File_Exists(path))
                continue
            DllCall("gdiplus\GdipNewPrivateFontCollection", "Ptr*", coll)
            DllCall("gdiplus\GdipPrivateAddFontFile", "Ptr", coll, "WStr", path)
            if (DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "DejaVu Sans Mono", "Ptr", coll, "Ptr*", family) = 0) {
                this.collection := coll
                this.family := family
                break
            }
            DllCall("gdiplus\GdipDeletePrivateFontCollection", "Ptr*", coll)
        }
        for _, name in ["Consolas", "Courier New"] {
            if (this.family)
                break
            if (DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", name, "Ptr", 0, "Ptr*", family) = 0)
                this.family := family
        }
        ; em size = 13 px * unitsPerEm / (ascender - descender) of DejaVu Sans Mono
        DllCall("gdiplus\GdipCreateFont", "Ptr", this.family, "Float", 13.0 * 2048 / 2384, "Int", 0, "Int", 2, "Ptr*", hFont)
        this.font := hFont
        DllCall("gdiplus\GdipStringFormatGetGenericTypographic", "Ptr*", generic)
        DllCall("gdiplus\GdipCloneStringFormat", "Ptr", generic, "Ptr*", hFormat)
        DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", hFormat, "Int", 1)
        DllCall("gdiplus\GdipSetStringFormatFlags", "Ptr", hFormat, "Int", 0x1000 | 0x4000)
        this.format := hFormat
        this.lineHeight := 13
        Gdip_SetTextRenderingHint(G, 4)
    }

    DrawCentered(text, x, y, w, color) {
        brush := Gdip_BrushCreateSolid(color)
        VarSetCapacity(rect, 16, 0)
        NumPut(x, rect, 0, "Float"), NumPut(y, rect, 4, "Float")
        NumPut(w, rect, 8, "Float"), NumPut(this.lineHeight + 4, rect, 12, "Float")
        DllCall("gdiplus\GdipDrawString", "Ptr", this.G, "WStr", text, "Int", -1, "Ptr", this.font
            , "Ptr", &rect, "Ptr", this.format, "Ptr", brush)
        Gdip_DeleteBrush(brush)
    }

    Dispose() {
        DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", this.format)
        DllCall("gdiplus\GdipDeleteFont", "Ptr", this.font)
        DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", this.family)
        if (this.collection) {
            coll := this.collection
            DllCall("gdiplus\GdipDeletePrivateFontCollection", "Ptr*", coll)
        }
    }
}
