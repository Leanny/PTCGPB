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
; ShopPack_ScrollToRow - Scroll the (freshly opened, still at the top) pack list
; so grid row `row` (0-based) is on screen. Every drag moves the list by
; ~198px (the grid rows are 285px apart) and the list stops at the bottom
; after ~2094px.
; Returns the device Y of the center of the pack artwork of that row.
;-------------------------------------------------------------------------------
ShopPack_ScrollToRow(row) {
    SHOP_DRAG_SHIFT := 198
    SHOP_FIRST_DRAG_LOSS := 147 ; the first drag moves the list ~147px less
    SHOP_DRAG_X := 8 ; far left gutter: left of the tiles, so a drag never taps a pack
    SHOP_LIST_MAX_SHIFT := 2094

    dragCommand := "input motionevent DOWN " . SHOP_DRAG_X . " 650;"
    Loop, 10
        dragCommand .= "input motionevent MOVE " . SHOP_DRAG_X . " " . (650 - A_Index * 25) . ";"
    dragCommand .= "sleep 0.4;input motionevent UP " . SHOP_DRAG_X . " 400"

    ; Device pixels. The artwork of row 0 starts at y=252 and is ~140px high.
    ; Aim for the artwork top at ~y=300.
    ; Rows 0 and 1 are already fully visible when the list is opened.
    drags := (row <= 1) ? 0 : Max(1, Round((285 * row - 48 + SHOP_FIRST_DRAG_LOSS) / SHOP_DRAG_SHIFT))
    Loop, % drags {
        adbWriteRaw(dragCommand)
        ; adbWriteRaw returns when the drag is done; let the list settle.
        DelayH(1500)
    }
    shift := (drags = 0) ? 0 : Min(drags * SHOP_DRAG_SHIFT - SHOP_FIRST_DRAG_LOSS, SHOP_LIST_MAX_SHIFT)
    return 252 + 285 * row - shift + 70
}

;-------------------------------------------------------------------------------
; ShopPack_OpenDialog - Tap the pack tile at logical (tapX, tapY) until the
; purchase dialog of the pack is open (its blue OK button is visible).
; Never press OK blindly: if the tile tap was ignored, the OK position would
; hit another pack of the list. Returns true when the dialog is open and the
; OK button is enabled (a greyed-out OK means not enough currency).
;-------------------------------------------------------------------------------
ShopPack_OpenDialog(tapX, tapY, timeoutSeconds := 15) {
    global session

    session.set("failSafe", A_TickCount)
    lastTap := 0
    Loop {
        if (A_TickCount - lastTap > 3000) {
            adbClick_wbb(tapX, tapY)
            lastTap := A_TickCount
        }
        Delay(2)
        if (FindOrLoseImage("Shop_PackDialogOK", 0, 0, 60, true)) {
            DelayH(1000) ; let the dialog finish animating in
            return true
        }
        if ((A_TickCount - session.get("failSafe")) // 1000 > timeoutSeconds) {
            adbTakeScreenshot(A_ScriptDir . "\..\Logs\ShopClaim_dialog_fail.png")
            LogWarn("ShopPack_OpenDialog: pack dialog did not open", "ShopClaim.txt")
            return false
        }
    }
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
    global session, g_shopPackTapX, g_shopPackTapY

    SHOP_PACK_COLUMNS_X := [68, 141, 228]

    packIndex := 0
    For idx, id in session.get("shopPackOrder") {
        if (id = packID)
            packIndex := idx - 1
    }
    if (!packIndex && session.get("shopPackOrder")[1] != packID) {
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

    row := packIndex // 3
    col := Mod(packIndex, 3) + 1
    deviceY := ShopPack_ScrollToRow(row)
    DelayH(1000)
    LogDebug("GoToShopPack: pack=" . ShopPack_Name(packID) . " row=" . row . " col=" . col . " deviceY=" . deviceY, "ShopClaim.txt")
    CreateStatusMessage("Opening shop pack " . ShopPack_Name(packID))
    g_shopPackTapX := SHOP_PACK_COLUMNS_X[col]
    g_shopPackTapY := ShopPack_DeviceToLogicalY(deviceY)

    return ShopPack_OpenDialog(g_shopPackTapX, g_shopPackTapY)
}

;-------------------------------------------------------------------------------
; ShopPack_HasNoCurrency - True if the ticket counter at the top of the shop
; list shows 0.
;-------------------------------------------------------------------------------
ShopPack_HasNoCurrency() {
    return FindOrLoseImage("Shop_NoTickets", 0, 0, 60, true)
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
    global session, g_shopPackTapX, g_shopPackTapY

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
        if (!ShopPack_OpenDialog(g_shopPackTapX, g_shopPackTapY))
            return false
    }

    adbClick_wbb(202, 387)

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    lastOkTap := A_TickCount
    Loop {
        Delay(1)
        if (FindOrLoseImage("Shop_ExchangeDoneButton", 0, 0, 60, true)) {
            adbClick_wbb(141, 364) ; OK of "Exchange completed"
            Delay(1)
            LogDebug("BuyShopPack: bought pack", "ShopClaim.txt")
            return true
        }
        ; The OK tap is ignored while the dialog is still animating in: tap
        ; again every 4s, but only while the pack dialog is open.
        if (A_TickCount - lastOkTap > 4000 && FindOrLoseImage("Shop_PackDialogOK", 0, 0, 60, true)) {
            adbClick_wbb(202, 387)
            lastOkTap := A_TickCount
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for purchase to complete...(" . failSafeTime . "/" . purchaseTimeoutSeconds . " seconds)")
        if (failSafeTime > purchaseTimeoutSeconds) {
            LogWarn("BuyShopPack: timed out waiting for purchase to complete", "ShopClaim.txt")
            return false
        }
    }
}
