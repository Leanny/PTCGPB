;-------------------------------------------------------------------------------
; GoToShopFromHome - Click the Shop tile on the Home screen.
; Requires the Home screen (Common_ShopButtonInMain visible). Clicks the tile
; and returns true as soon as Home has been left (the Shop needle disappears),
; false if Home was not detected or the click had no effect within the timeout.
;-------------------------------------------------------------------------------
GoToShopFromHome(timeoutSeconds := 20) {
    global session

    if (!FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true)) {
        LogDebug("GoToShopFromHome: Home not detected, moving to Main first")
        Loop, 10 {
            if (FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true))
                break
            if (FindOrLoseImage("Shop_TicketIcon", 0, 0, , true)
                || FindOrLoseImage("Shop_PackDialogOK", 0, 0, , true)) {
                adbClick_wbb(141, 500) ; shop close X
                DelayH(600)
                continue
            }
            adbClick_wbb(40, 516) ; bottom-nav Home icon
            DelayH(500)
            if (FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true))
                break
            adbClick_wbb(175, 445) ; dismiss any overlay/popup
            DelayH(500)
        }
        if (!FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true)) {
            LogWarn("GoToShopFromHome: Home screen not detected (Common_ShopButtonInMain missing)")
            return false
        }
    }

    GoToMain()
    if (!FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true)) {
        LogWarn("GoToShopFromHome: Home screen lost after GoToMain")
        return false
    }

    ; Tap once and wait. The same coordinates hit a shop item once the shop is
    ; open, so only tap again if Home is still showing after a long wait.
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    lastTap := 0
    Loop {
        if (lastTap = 0 || (A_TickCount - lastTap > 8000 && FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true))) {
            adbClick_wbb(207, 391)
            lastTap := A_TickCount
        }
        Delay(1)

        ; The Home "Shop" label is gone once the shop page is open.
        if (FindOrLoseImage("Common_ShopButtonInMain", 1, 0, , true)) {
            LogDebug("GoToShopFromHome: left Home screen, shop opened")
            return true
        }

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Opening Shop...(" . failSafeTime . "/" . timeoutSeconds . " seconds)")
        if (failSafeTime > timeoutSeconds) {
            LogWarn("GoToShopFromHome: timed out waiting for shop to open")
            return false
        }
    }
}

;-------------------------------------------------------------------------------
; ClaimShopDailyGift - Open the shop from Home and claim the free daily gift.
; If the red "!" dot (Shop_DailyGiftDot) is on the gift card, click the card,
; wait for the blue OK button of the "Exchange completed" dialog, confirm it
; and return to Main with GoToMain().
; Returns true if a gift was claimed, false if there was nothing to claim or
; something timed out (GoToMain is called in every case after the shop opened).
;-------------------------------------------------------------------------------
ClaimShopDailyGift(loadTimeoutSeconds := 60, purchaseTimeoutSeconds := 30) {
    global session

    if (!GoToShopFromHome())
        return false

    ; The shop content loads after the page opens: the ticket icon at the top
    ; shows up once it is loaded.
    shopLoaded := false
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if (FindOrLoseImage("Shop_TicketIcon", 0, 0, , true)) {
            shopLoaded := true
            LogDebug("ClaimShopDailyGift: shop loaded after " . failSafeTime . "s")
            break
        }
        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for shop to load...(" . failSafeTime . "/" . loadTimeoutSeconds . " seconds)")
        if (failSafeTime > loadTimeoutSeconds) {
            LogWarn("ClaimShopDailyGift: shop did not load in time")
            break
        }
    }

    ; Loaded: the dot is either there or the gift was already claimed. Give the
    ; page a moment to draw it, then decide.
    claimed := false
    if (shopLoaded) {
        Loop, 4 {
            if (FindOrLoseImage("Shop_DailyGiftDot", 0, 0, , true)) {
                adbClick(149, 234)
                claimed := true
                break
            }
            Delay(1)
        }
        if (!claimed)
            LogDebug("ClaimShopDailyGift: no daily gift dot found, nothing to claim")
    }

    if (claimed) {
        ; Wait for the purchase to complete: blue OK button.
        claimed := false
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop {
            Delay(1)
            ; The OK button pulses in color, so use a higher tolerance (60).
            if (FindOrLoseImage("Shop_PurchaseOKButton", 0, 0, 60, true)) {
                adbClick_wbb(141, 364) ; OK
                Delay(1)
                claimed := true
                LogDebug("ClaimShopDailyGift: daily gift claimed")
                break
            }
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            CreateStatusMessage("Waiting for purchase to complete...(" . failSafeTime . "/" . purchaseTimeoutSeconds . " seconds)")
            if (failSafeTime > purchaseTimeoutSeconds) {
                LogWarn("ClaimShopDailyGift: timed out waiting for purchase OK button")
                break
            }
        }
    }

    GoToMain()
    return claimed
}

; Logical position of the pack tile GoToShopPack opened last (BuyShopPack reopens it).
global g_shopPackTapX := 0
global g_shopPackTapY := 0

; Localised name of a shop pack (Txt_ShopPack_<ItemID> of the dictionary in the
; bot language), for log and status messages. Falls back to English, then the ID.
ShopPack_Name(packID) {
    global botConfig, dictionaryData

    name := dictionaryData[botConfig.get("defaultBotLanguage")]["Txt_ShopPack_" . packID]
    if (name = "")
        name := dictionaryData["en"]["Txt_ShopPack_" . packID]
    return (name = "") ? packID : name
}

ShopPack_DeviceToLogicalY(deviceY) {
    return Round(deviceY * 488 / 960 + 40)
}

;-------------------------------------------------------------------------------
; ShopPack_PickPack - Choose the pack to claim: random from the packs selected
; in "Select Pack", or the first pack of the list (Genetic Apex: Mewtwo) if
; nothing is selected. The account's claimedShopPacks only counts how many
; packs were claimed, so previously claimed packs can be picked again.
;-------------------------------------------------------------------------------
ShopPack_PickPack() {
    global session

    shopPackOrder := session.get("shopPackOrder")
    selectedMap := GetSelectedShopPackIDs()

    candidates := []
    For idx, packID in shopPackOrder {
        if (selectedMap.HasKey(packID))
            candidates.Push(packID)
    }
    if (candidates.MaxIndex() = "")
        return shopPackOrder[1] ; nothing selected: first pack (Genetic Apex: Mewtwo)

    Random, pick, 1, % candidates.MaxIndex()
    return candidates[pick]
}

;-------------------------------------------------------------------------------
; ShopPack_LocaleLabel - packID -> normalized pack name in the game language.
; The shop tile label is the first line of the PACK_DESC_<code>_<slot>_0N
; locale string ("<name> (1 star card guaranteed) ..."); the (1... suffix is
; identical on every tile so only the name part is used for matching. The
; PACK_DESC key is found by comparing its English name part with the ItemID's
; English dictionary name, then the same key is read in the game locale.
;-------------------------------------------------------------------------------
ShopPack_LocaleLabel(packID, localeFile) {
    global dictionaryData

    enName := dictionaryData["en"]["Txt_ShopPack_" . packID]
    if (enName = "")
        return ""
    enNorm := ShopPack_OcrNorm(enName)

    base := getScriptBaseFolder() . "\Helper\"
    resUrl := "https://leanny.github.io/pocket_tcg_resources/data/"
    if (!CardName_DownloadIfMissing(base . "en_US.json", resUrl . "en_US.json"))
        return ""
    FileRead, enJson, % base . "en_US.json"
    if (ErrorLevel)
        return ""
    key := "", pos := 0
    while (pos := RegExMatch(enJson, """(PACK_DESC_\w+_\d+_0\d)""\s*:\s*""((?:[^""\\]|\\.)*)""", m, pos + 1)) {
        first := StrSplit(ShopPack_JsonUnescape(m2), "`n")[1]
        namePart := RegExReplace(first, "\s*\(.*$", "")
        if (ShopPack_OcrNorm(namePart) = enNorm) {
            key := m1
            break
        }
    }
    if (key = "")
        return ""

    if (localeFile != "en_US")
        CardName_DownloadIfMissing(base . localeFile . ".json", resUrl . localeFile . ".json")
    FileRead, locJson, % base . localeFile . ".json"
    if (ErrorLevel)
        locJson := enJson
    if (RegExMatch(locJson, """" . key . """\s*:\s*""((?:[^""\\]|\\.)*)""", lm)) {
        first := StrSplit(ShopPack_JsonUnescape(lm1), "`n")[1]
        namePart := RegExReplace(first, "\s*\(.*$", "")
        return ShopPack_OcrNorm(namePart)
    }
    return ""
}

;-------------------------------------------------------------------------------
; ShopPack_OcrClusterRows - Words of one grid column, sorted by y then x and
; grouped into blocks where consecutive lines sit <20px apart (a pack label
; wraps up to ~3 lines with ~2-9px gaps; the "38 days" badges and the next
; tile's label sit much further away, so they form their own blocks).
;-------------------------------------------------------------------------------
ShopPack_OcrClusterRows(words) {
    if (!IsObject(words) or words.MaxIndex() = "")
        return []
    sorted := []
    for _, w in words {
        inserted := false
        Loop, % sorted.MaxIndex() + 0 {
            if (w.y < sorted[A_Index].y or (w.y = sorted[A_Index].y and w.x < sorted[A_Index].x)) {
                sorted.InsertAt(A_Index, w), inserted := true
                break
            }
        }
        if (!inserted)
            sorted.Push(w)
    }
    blocks := [], cur := []
    for _, w in sorted {
        prev := cur[cur.MaxIndex()]
        if (cur.MaxIndex() = "" or w.y - prev.y - prev.h < 20)
            cur.Push(w)
        else
            blocks.Push(cur), cur := [w]
    }
    if (cur.MaxIndex() != "")
        blocks.Push(cur)
    return blocks
}

;-------------------------------------------------------------------------------
; ShopPack_OcrFindPack - Locate the pack tile whose label starts with the
; normalized target name. Returns {x,y} device px of the artwork center above
; the label, false if absent. The "38 days" badges sit on the artwork and
; cluster separately, so they never merge into a label block.
;-------------------------------------------------------------------------------
ShopPack_OcrFindPack(words, targetNorm) {
    blocks := [[], [], []] ; must exist before any blocks[i] access: reading a missing key freezes the var as scalar and later indexed writes are silently dropped
    for _, w in words {
        cy := w.y + w.h / 2
        if (cy < 90 or cy > 745) ; below the title bar, above the category chip bar (labels of the last visible row reach cy~730)
            continue
        col := (w.x + w.w / 2 < 185) ? 1 : (w.x + w.w / 2 < 350 ? 2 : 3)
        blocks[col].Push(w)
    }
    Loop, 3 {
        for _, blk in ShopPack_OcrClusterRows(blocks[A_Index]) {
            txt := ""
            for _, w in blk
                txt .= w.text
            if (InStr(ShopPack_OcrNorm(txt), targetNorm) = 1) {
                top := blk[1]
                tapY := top.y - 100 ; artwork center above the label
                if (tapY < 90)
                    continue ; tile mostly off-screen, it will reappear after scrolling
                return {x: Round(top.x + top.w / 2), y: tapY}
            }
        }
    }
    return false
}

;-------------------------------------------------------------------------------
; ShopPack_SelectPackOcr - Scroll the Limited Time pack list until OCR reads
; the target pack's label, then open its purchase dialog. The scroll distance
; is nondeterministic so positions are never assumed: every iteration takes a
; fresh screencap and re-clusters the grid.
;-------------------------------------------------------------------------------
ShopPack_SelectPackOcr(packID, maxScrolls := 8) {
    global session, g_shopPackTapX, g_shopPackTapY, g_shopPackTarget, g_shopPackNames, g_shopPackOcrTag

    locale := ShopPack_OcrLocale()
    target := ShopPack_LocaleLabel(packID, locale.file)
    names := ShopPack_LocaleNames(locale.file)
    if (target = "") {
        LogWarn("ShopPack: no locale label for " . ShopPack_Name(packID), "ShopClaim.txt")
        return false
    }
    shotFile := A_Temp . "\shopsel_" . session.get("scriptName") . ".png"
    prevSig := "", reversed := false
    Loop, % maxScrolls + 1 {
        CreateStatusMessage("Searching " . ShopPack_Name(packID) . "...")
        cmd := """" . session.get("adbPath") . """ -s " . AdbAddress() . " exec-out screencap -p > """ . shotFile . """"
        RunWait, %ComSpec% /c "%cmd%", , Hide
        words := ShopPack_RapidOcr(shotFile, locale.ocr)
        if (IsObject(words)) {
            tap := ShopPack_OcrFindPack(words, target)
            if (IsObject(tap)) {
                g_shopPackTapX := Round(tap.x * 283 / 540)
                g_shopPackTapY := ShopPack_DeviceToLogicalY(tap.y)
                g_shopPackTarget := target, g_shopPackNames := names, g_shopPackOcrTag := locale.ocr
                if (ShopPack_OpenDialog(g_shopPackTapX, g_shopPackTapY, target, names, locale.ocr)) {
                    LogDebug("ShopPack: dialog shows " . ShopPack_Name(packID), "ShopClaim.txt")
                    return true
                }
                adbInputEvent("111") ; open failed, dismiss whatever is up and keep scanning
                Sleep, 500
            } else {
                r := ShopPack_ScanPackNames(words, names, target)
                LogDebug("ShopPack: label miss target=" . r.target . " others=" . r.others, "ShopClaim.txt")
            }
            sig := ""
            for _, w in words
                sig .= w.text . "@" . Round(w.x / 8) . "," . Round(w.y / 8) . "|" ; positions included: identical text at a shifted scroll offset must not read as "list end"
            if (sig != "" and sig = prevSig) {
                if (reversed)
                    break ; scanned both directions, target really absent
                reversed := true
            } else {
                prevSig := sig
            }
        }
        if (A_Index > maxScrolls)
            break
        CreateStatusMessage(ShopPack_Name(packID) . " not visible, scrolling list...")
        if (reversed)
            adbSwipe("8 350 8 650 300") ; scroll back up toward the top
        else
            adbSwipe("8 650 8 250 300") ; reveal rows below
        adbWriteRaw("input tap 8 500") ; tap the left margin to halt inertial scrolling
        Sleep, 500 ; let the list fully settle before the next screencap
    }
    LogWarn("ShopPack: " . ShopPack_Name(packID) . " not found in the shop list", "ShopClaim.txt")
    return false
}

;-------------------------------------------------------------------------------
; ShopPack_LocaleNames - Normalized name parts of every PACK_DESC_* first
; line in the game locale JSON (localized, so matching works in any language).
; Used to tell "the selected pack's name is the only one on screen" (dialog)
; from "several pack names visible" (the list grid) without any needle.
;-------------------------------------------------------------------------------
ShopPack_LocaleNames(localeFile) {
    static cache := {}
    if (cache.HasKey(localeFile))
        return cache[localeFile]
    base := getScriptBaseFolder() . "\Helper\"
    resUrl := "https://leanny.github.io/pocket_tcg_resources/data/"
    CardName_DownloadIfMissing(base . localeFile . ".json", resUrl . localeFile . ".json")
    FileRead, locJson, % base . localeFile . ".json"
    if (ErrorLevel)
        locJson := ""
    names := [], pos := 0
    while (pos := RegExMatch(locJson, """PACK_DESC_\w+""\s*:\s*""((?:[^""\\]|\\.)*)""", m, pos + 1)) {
        first := StrSplit(ShopPack_JsonUnescape(m1), "`n")[1]
        nm := ShopPack_OcrNorm(RegExReplace(first, "\s*\(.*$", ""))
        if (nm != "")
            names.Push(nm)
    }
    cache[localeFile] := names
    return names
}

;-------------------------------------------------------------------------------
; ShopPack_ScanPackNames - Count the pack names visible on screen: returns
; {target: found?, others: how many other known pack names}. The purchase or
; detail dialog shows only the selected pack's name; the list grid shows
; several. Blocks are clustered first because labels wrap onto several lines.
;-------------------------------------------------------------------------------
ShopPack_ScanPackNames(words, names, target) {
    res := {target: false, others: 0, hits: 0}
    joined := ""
    for _, blk in ShopPack_OcrClusterRows(words) {
        txt := ""
        for _, w in blk
            txt .= w.text
        n := ShopPack_OcrNorm(txt)
        if (InStr(n, target) > 0)
            res.target := true
        joined .= n . " "
    }
    ; Count each distinct other pack name once. Row clustering can merge the
    ; three grid columns into one block, so a per-block count would stop at
    ; the first matching name and the list would read as others=1.
    for _, nm in names {
        if (nm != target and InStr(joined, nm) > 0)
            res.others++
    }
    ; The pack detail page repeats the name in title and description (hits=2);
    ; the purchase dialog shows it once. Lets callers tell the two apart.
    pos := 1
    while (pos := InStr(joined, target, false, pos)) {
        res.hits++
        pos += StrLen(target)
    }
    return res
}

;-------------------------------------------------------------------------------
; ShopPack_OpenDialog - Tap the pack tile at logical (tapX, tapY), then wait
; until the selected pack's name is the ONLY pack name on screen: that means
; its dialog (purchase or detail page) is open. Re-taps only while the list
; grid is clearly still visible (several pack names): a blind tap on an open
; dialog would open its detail page or hit something unintended. A single
; foreign pack name means a different pack's dialog opened: dismiss with ESC.
;-------------------------------------------------------------------------------
ShopPack_OpenDialog(tapX, tapY, target, names, ocrTag, timeoutSeconds := 15) {
    global session

    session.set("failSafe", A_TickCount)
    shotFile := A_Temp . "\shopdlg_" . session.get("scriptName") . ".png"
    adbClick_wbb(tapX, tapY)
    lastTap := A_TickCount, dismissed := 0, lastSeen := "", lastState := -1
    Loop {
        cmd := """" . session.get("adbPath") . """ -s " . AdbAddress() . " exec-out screencap -p > """ . shotFile . """"
        RunWait, %ComSpec% /c "%cmd%", , Hide
        words := ShopPack_RapidOcr(shotFile, ocrTag, 20, 320, 500, 290) ; dialog title band + pack detail title/description zone
        if (IsObject(words)) {
            r := ShopPack_ScanPackNames(words, names, target)
            seen := ""
            for _, w in words
                seen .= w.text . "|"
            state := (r.target ? 1 : 0) . "," . r.others
            if (seen != lastSeen || state != lastState) {
                LogDebug("ShopPack_OpenDialog: seen=""" . seen . """ target=" . r.target . " others=" . r.others, "ShopClaim.txt")
                lastSeen := seen, lastState := state
            }
            if (r.target and r.others = 0 and r.hits <= 1)
                return true
            ; The pack detail page repeats the name (title + description): it
            ; is not the purchase dialog - close it and keep trying.
            if (r.others = 0 and r.hits >= 2) {
                adbInputEvent("111")
                LogInfo("ShopPack_OpenDialog: dismissed pack detail page", "ShopClaim.txt")
                Sleep, 600
                lastTap := A_TickCount
                if (++dismissed >= 3)
                    break
                continue
            }
            ; A real foreign-pack dialog shows only its title in the band (few
            ; words). A lone label on the list comes with tile/text fragments:
            ; treat a busy band as the list, never ESC on it.
            listish := (r.others >= 2 or r.target or words.Count() > 5)
            if (!r.target and r.others = 1 and !listish) {
                adbInputEvent("111") ; another pack's dialog is open, close it
                LogInfo("ShopPack_OpenDialog: dismissed a different pack's dialog", "ShopClaim.txt")
                Sleep, 600
                lastTap := A_TickCount
                if (++dismissed >= 3)
                    break
                continue
            }
            if (listish and A_TickCount - lastTap > 3000) {
                adbClick_wbb(tapX, tapY) ; still on the list: the tile tap was ignored
                lastTap := A_TickCount
            }
        }
        if ((A_TickCount - session.get("failSafe")) // 1000 > timeoutSeconds)
            break
        Sleep, 400
    }
    dumpFile := getScriptBaseFolder() . "\Screenshots\Stuck\shopdlg_" . session.get("scriptName") . "_" . A_TickCount . ".png"
    FileCopy, %shotFile%, %dumpFile%, 1
    LogWarn("ShopPack_OpenDialog: pack dialog did not open - cap: " . dumpFile, "ShopClaim.txt")
    return false
}

;-------------------------------------------------------------------------------
; GoToShopPack - Open the shop from Home, go to "Limited Time / Events" and
; open the purchase dialog of the pack `packID` (ItemID from packdata.dat).
; Returns true when the dialog is open and a pack can be bought with
; BuyShopPack(). Returns false if the shop did not load, the pack dialog did
; not open or there is no currency (0 tickets). The caller is responsible for
; calling GoToMain() afterwards in every case.
;-------------------------------------------------------------------------------
GoToShopPack(packID, loadTimeoutSeconds := 60) {
    global session

    known := false
    For idx, id in session.get("shopPackOrder") {
        if (id = packID)
            known := true
    }
    if (!known) {
        LogWarn("GoToShopPack: unknown pack " . ShopPack_Name(packID), "ShopClaim.txt")
        return false
    }

    if (!GoToShopFromHome())
        return false

    shopLoaded := false
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if (FindOrLoseImage("Shop_TicketIcon", 0, 0, , true)) {
            shopLoaded := true
            break
        }
        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for shop to load...(" . failSafeTime . "/" . loadTimeoutSeconds . " seconds)")
        if (failSafeTime > loadTimeoutSeconds) {
            LogWarn("GoToShopPack: shop did not load in time", "ShopClaim.txt")
            return false
        }
    }

    ; The tab is ignored while the shop content is still loading, and tapping
    ; the already active tab is harmless, so tap it twice.
    Delay(3)
    adbClick_wbb(204, 458)
    Delay(2)
    adbClick_wbb(204, 458)
    Delay(3)

    if (ShopPack_HasNoCurrency()) {
        LogDebug("GoToShopPack: 0 tickets, nothing to buy", "ShopClaim.txt")
        return false
    }

    CreateStatusMessage("Opening shop pack " . ShopPack_Name(packID))
    LogDebug("GoToShopPack: locating " . ShopPack_Name(packID) . " via OCR", "ShopClaim.txt")
    return ShopPack_SelectPackOcr(packID)
}

;-------------------------------------------------------------------------------
; ShopPack_HasNoCurrency - True if the ticket counter at the top of the shop
; list shows 0.
;-------------------------------------------------------------------------------
ShopPack_HasNoCurrency(words := "") {
    return (ShopPack_TicketCount(words) = 0)
}

;-------------------------------------------------------------------------------
; ShopPack_ShopWords - Single screencap + OCR pass, shared by the ticket
; counter and the pack-name scan so each loop iteration costs one capture.
;-------------------------------------------------------------------------------
ShopPack_ShopWords(shotFile, ocrTag := "", cX := 0, cY := 0, cW := 0, cH := 0) {
    global session
    cmd := """" . session.get("adbPath") . """ -s " . AdbAddress() . " exec-out screencap -p > """ . shotFile . """"
    RunWait, %ComSpec% /c "%cmd%", , Hide
    return ShopPack_RapidOcr(shotFile, ocrTag, cX, cY, cW, cH)
}

;-------------------------------------------------------------------------------
; ShopPack_TicketCount - Ticket counter value in the top pill of the shop
; list, read via OCR. -1 when unreadable; callers then proceed as if currency
; were left, same as the old Shop_NoTickets needle not matching. Pass OCR
; words to reuse an existing capture instead of taking a new one.
;-------------------------------------------------------------------------------
ShopPack_TicketCount(words := "") {
    global session
    if (!IsObject(words)) {
        shotFile := A_Temp . "\shoptickets_" . session.get("scriptName") . ".png"
        words := ShopPack_ShopWords(shotFile, "", 310, 30, 150, 70) ; ticket pill number only
        if (!IsObject(words))
            return -1
    }
    raw := ""
    for _, w in words
        raw .= w.text . "|"
    for _, w in words {
        cx := w.x + w.w / 2, cy := w.y + w.h / 2
        if (cx > 290 and cx < 470 and cy > 40 and cy < 100 and RegExMatch(w.text, "^\d+$")) {
            LogDebug("ShopPack_TicketCount: " . w.text . " (seen=""" . raw . """)", "ShopClaim.txt")
            return w.text + 0
        }
    }
    LogDebug("ShopPack_TicketCount: unreadable (seen=""" . raw . """)", "ShopClaim.txt")
    return -1
}

;-------------------------------------------------------------------------------
; BuyShopPack - Buy the pack GoToShopPack() opened, once. After a purchase the
; game returns to the pack list, so the same pack tile is opened again when
; needed; call it repeatedly while it returns true to buy more of the pack.
; Returns true when a pack was bought and false if nothing was bought (no
; currency left, the dialog did not open or the purchase did not complete).
; The caller is responsible for GoToMain() afterwards.
;-------------------------------------------------------------------------------
BuyShopPack(purchaseTimeoutSeconds := 30) {
    global session, g_shopPackTapX, g_shopPackTapY, g_shopPackTarget, g_shopPackNames, g_shopPackOcrTag

    if (!g_shopPackTapX) {
        LogWarn("BuyShopPack: no pack opened, call GoToShopPack first", "ShopClaim.txt")
        return false
    }

    ; Dialog closed (after a previous purchase the list is shown again)?
    if (!FindOrLoseImage("Shop_PackDialogOK", 0, 0, 60, true)) {
        if (ShopPack_HasNoCurrency()) {
            LogDebug("BuyShopPack: 0 tickets left", "ShopClaim.txt")
            return false
        }
        if (!ShopPack_OpenDialog(g_shopPackTapX, g_shopPackTapY, g_shopPackTarget, g_shopPackNames, g_shopPackOcrTag))
            return false
    }

    adbClick_wbb(202, 387)

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    lastOkTap := A_TickCount
    lastNeedle := A_TickCount
    bails := 0
    giveUp := false
    Loop {
        Delay(1)
        if (FindOrLoseImage("Shop_ExchangeDoneButton", 0, 0, 60, true)) {
            ; Dismiss "Exchange completed". Its OK tap can be ignored while
            ; the dialog is animating in: retap every 2s until it closes.
            doneStart := A_TickCount
            lastDoneTap := 0
            Loop {
                if (lastDoneTap = 0 || A_TickCount - lastDoneTap > 2000) {
                    adbInputEvent("111") ; dismiss "Exchange completed" with back
                    lastDoneTap := A_TickCount
                }
                Delay(2)
                if (!FindOrLoseImage("Shop_ExchangeDoneButton", 0, 0, 60, true))
                    break
                if (A_TickCount - doneStart > 8000)
                    break
            }
            LogDebug("BuyShopPack: bought pack", "ShopClaim.txt")
            return true
        }
        ; The OK tap is ignored while the dialog is still animating in: tap
        ; again every 4s, but only while the pack dialog is open.
        if (FindOrLoseImage("Shop_PackDialogOK", 0, 0, 60, true)) {
            lastNeedle := A_TickCount
            if (A_TickCount - lastOkTap > 4000) {
                adbClick_wbb(202, 387)
                lastOkTap := A_TickCount
            }
        }
        ; 8s with neither needle: something is on top of the purchase dialog
        ; (pack detail page, stray dialog). The pill is readable only on the
        ; list: dimmed means a modal is up, so peel it with ESC and resume -
        ; the purchase dialog resurfaces underneath. Give up after 2 tries.
        else if (A_TickCount - lastNeedle > 8000) {
            if (++bails <= 2 && ShopPack_TicketCount() < 0) {
                adbInputEvent("111")
                Delay(2)
                lastNeedle := A_TickCount
                continue
            }
            giveUp := true
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for purchase to complete...(" . failSafeTime . "/" . purchaseTimeoutSeconds . " seconds)")
        if (failSafeTime > purchaseTimeoutSeconds || giveUp) {
            ; Final check only (no per-loop OCR): dismiss any lingering modal
            ; and confirm the pack list is back. Covers a completed purchase
            ; whose needles never matched. The pill is unreadable only while a
            ; modal covers it - ESC on the bare list would exit the shop.
            if (ShopPack_TicketCount() < 0) {
                adbInputEvent("111")
                Delay(1)
            }
            words := ShopPack_ShopWords(A_Temp . "\shopbuy_" . session.get("scriptName") . ".png", g_shopPackOcrTag)
            if (IsObject(words)) {
                r := ShopPack_ScanPackNames(words, g_shopPackNames, g_shopPackTarget)
                if (r.others >= 2) {
                    LogDebug("BuyShopPack: bought pack (list reappeared)", "ShopClaim.txt")
                    return true
                }
            }
            LogWarn("BuyShopPack: timed out waiting for purchase to complete", "ShopClaim.txt")
            return false
        }
    }
}


ShopPack_OcrFold(s) {
    static table := "ß>ss`nẞ>ss`nœ>oe`nŒ>oe`næ>ae`nÆ>ae`n"
        . "à>a`ná>a`nâ>a`nã>a`nä>a`nå>a`nā>a`nă>a`ną>a`n"
        . "À>a`nÁ>a`nÂ>a`nÃ>a`nÄ>a`nÅ>a`nĀ>a`nĂ>a`nĄ>a`n"
        . "ç>c`nć>c`nč>c`nÇ>c`nĆ>c`nČ>c`n"
        . "è>e`né>e`nê>e`në>e`nē>e`nĕ>e`nė>e`nę>e`ně>e`n"
        . "È>e`nÉ>e`nÊ>e`nË>e`nĒ>e`nĔ>e`nĖ>e`nĘ>e`nĚ>e`n"
        . "ì>i`ní>i`nî>i`nï>i`nī>i`nĭ>i`nį>i`nı>i`n"
        . "Ì>i`nÍ>i`nÎ>i`nÏ>i`nĪ>i`nĬ>i`nĮ>i`nİ>i`n"
        . "ñ>n`nń>n`nň>n`nÑ>n`nŃ>n`nŇ>n`n"
        . "ò>o`nó>o`nô>o`nõ>o`nö>o`nø>o`nō>o`nŏ>o`nő>o`n"
        . "Ò>o`nÓ>o`nÔ>o`nÕ>o`nÖ>o`nØ>o`nŌ>o`nŎ>o`nŐ>o`n"
        . "ù>u`nú>u`nû>u`nü>u`nū>u`nŭ>u`nů>u`nű>u`nų>u`n"
        . "Ù>u`nÚ>u`nÛ>u`nÜ>u`nŪ>u`nŬ>u`nŮ>u`nŰ>u`nŲ>u`n"
        . "ý>y`nÿ>y`nÝ>y`nŸ>y`n"
        . "š>s`nŠ>s`nž>z`nŽ>z`nď>d`nĎ>d`nť>t`nŤ>t`nĺ>l`nĹ>l`nŕ>r`nŔ>r"
    Loop, Parse, table, `n
        s := StrReplace(s, SubStr(A_LoopField, 1, 1), SubStr(A_LoopField, 3))
    return s
}

ShopPack_OcrUpper(s) {
    out := ""
    Loop, % StrLen(s) {
        c := SubStr(s, A_Index, 1)
        o := Ord(c)
        out .= (o >= 97 and o <= 122) ? Chr(o - 32) : c
    }
    return out
}

ShopPack_OcrNorm(s) {
    return RegExReplace(ShopPack_OcrUpper(ShopPack_OcrFold(s)), "[^\p{L}\p{N}]", "")
}

ShopPack_JsonUnescape(s) {
    out := "", p := 1
    While (q := RegExMatch(s, "i)\\u([0-9a-f]{4})", m, p)) {
        out .= SubStr(s, p, q - p) . Chr("0x" . m1)
        p := q + 6
    }
    return out . SubStr(s, p)
}

ShopPack_LocaleForLang(lang) {
    lang := Trim(lang)
    if (RegExMatch(lang, "i)^en"))
        return {file: "en_US", ocr: "en"}
    if (RegExMatch(lang, "i)^it"))
        return {file: "it_IT", ocr: "it"}
    if (RegExMatch(lang, "i)^de"))
        return {file: "de_DE", ocr: "de"}
    if (RegExMatch(lang, "i)^fr"))
        return {file: "fr_FR", ocr: "fr"}
    if (RegExMatch(lang, "i)^es"))
        return {file: "es_ES", ocr: "es"}
    if (RegExMatch(lang, "i)^pt"))
        return {file: "pt_BR", ocr: "pt"}
    if (RegExMatch(lang, "i)^(ja|jp)"))
        return {file: "ja_JP", ocr: "ja"}
    if (RegExMatch(lang, "i)^ko"))
        return {file: "ko_KR", ocr: "ko"}
    if (RegExMatch(lang, "i)^zh"))
        return {file: "zh_TW", ocr: "zh-Hant-TW"} ; the game only ships traditional Chinese
    return ""
}

ShopPack_OcrLocale() {
    global session
    lang := Trim(session.get("language"))
    if (lang = "") {
        accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), session.get("loadedAccount"))
        lang := Trim(accountMeta["language"])
    }
    loc := ShopPack_LocaleForLang(lang)
    if (loc = "")
        loc := {file: "en_US", ocr: "en"}
    return loc
}

ShopPack_RapidOcrLang(ocrTag) {
    ; The default ch_PP-OCRv4 recognizer already covers the Latin alphabet;
    ; CJK locales get their dedicated rec model + keyset from rapidocr\models.
    if (ocrTag = "ja")
        return " --rec rec_japan_PP-OCRv3_infer.onnx --keys dict_japan.txt"
    if (ocrTag = "ko")
        return " --rec rec_korean_PP-OCRv3_infer.onnx --keys dict_korean.txt"
    if (ocrTag ~ "^zh")
        return " --rec rec_chinese_cht_PP-OCRv3_infer.onnx --keys dict_chinese_cht.txt"
    return ""
}

;-------------------------------------------------------------------------------
; ShopPack_CropImage - Save a (x,y,w,h) slice of a PNG via GDI+. Used to OCR a
; small screen region instead of the full frame (much faster).
;-------------------------------------------------------------------------------
ShopPack_CropImage(srcFile, dstFile, x, y, w, h) {
    pBmp := Gdip_CreateBitmapFromFile(srcFile)
    if (!pBmp)
        return false
    pCrop := Gdip_CloneBitmapArea(pBmp, x, y, w, h)
    Gdip_DisposeImage(pBmp)
    if (!pCrop)
        return false
    ok := (Gdip_SaveBitmapToFile(pCrop, dstFile) = 0)
    Gdip_DisposeImage(pCrop)
    return ok
}

ShopPack_RapidOcr(shotFile, ocrTag := "", cX := 0, cY := 0, cW := 0, cH := 0) {
    global session
    static exe := ""
    static exeDir := ""
    if (exe = "") {
        exeDir := getScriptBaseFolder() . "\rapidocr"
        Loop, Files, %exeDir%\*RapidOCR*.exe
            exe := A_LoopFileFullPath
        if (exe = "")
            exeDir := getScriptBaseFolder() . "\rapidocr\RapidOCR-json_v0.2.0"
        Loop, Files, %exeDir%\*.exe
            if (InStr(A_LoopFileName, "RapidOCR")) {
                exe := A_LoopFileFullPath
                exeDir := A_LoopFileDir
                break
            }
        if (exe = "")
            exe := false
    }
    if (!exe)
        return ""
    ; Optional (cX,cY,cW,cH): OCR only that region of the frame. Returned word
    ; coordinates stay absolute (offset back), so callers are unchanged.
    ocrFile := shotFile
    if (cW > 0 && cH > 0) {
        cropFile := A_Temp . "\rapidocr_crop_" . session.get("scriptName") . ".png"
        if (ShopPack_CropImage(shotFile, cropFile, cX, cY, cW, cH))
            ocrFile := cropFile
        else
            cX := 0, cY := 0 ; crop failed: fall back to the full frame
    }
    cmd := """" . exe . """ --image_path """ . ocrFile . """ --ensureLogger 0 --doAngle 0 --mostAngle 0" . ShopPack_RapidOcrLang(ocrTag)
    outFile := A_Temp . "\rapidocr_" . session.get("scriptName") . ".json"
    RunWait, %ComSpec% /c cd /d "%exeDir%" && %cmd% > "%outFile%", , Hide
    if (!FileExist(outFile))
        return ""
    FileRead, json, *P65001 %outFile% ; RapidOCR emits UTF-8 without BOM
    FileDelete, %outFile%
    words := []
    pos := 1
    re := """box"":\[\[(\d+),(\d+)\],\[(\d+),(\d+)\],\[(\d+),(\d+)\],\[(\d+),(\d+)\]\],""score"":[\d\.eE+-]+,""text"":""([^""]*)"""
    While (p := RegExMatch(json, re, m, pos)) {
        if (m9 = "") {
            pos := p + StrLen(m)
            continue
        }
        xs := [m1 + 0, m3 + 0, m5 + 0, m7 + 0], ys := [m2 + 0, m4 + 0, m6 + 0, m8 + 0]
        minX := xs[1], maxX := xs[1], minY := ys[1], maxY := ys[1]
        for _, v in xs {
            if (v < minX)
                minX := v
            if (v > maxX)
                maxX := v
        }
        for _, v in ys {
            if (v < minY)
                minY := v
            if (v > maxY)
                maxY := v
        }
        words.Push({text: m9, x: minX + cX, y: minY + cY, w: maxX - minX, h: maxY - minY})
        pos := p + StrLen(m)
    }
    return words
}
