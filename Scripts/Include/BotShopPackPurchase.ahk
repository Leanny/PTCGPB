; Shop navigation and pack purchase helpers

; Click target for the "Shop" tile on the Home screen (logical bot coordinates,
; converted to device pixels by adbClick: x*540/283, (y-40)*960/488).
; Tile center on device is roughly (395, 690) -> logical (207, 391).
global SHOP_TILE_X := 207
global SHOP_TILE_Y := 391

;-------------------------------------------------------------------------------
; GoToShopFromHome - Click the Shop tile on the Home screen.
; Requires the Home screen (Common_ShopButtonInMain visible). Clicks the tile
; and returns true as soon as Home has been left (the Shop needle disappears),
; false if Home was not detected or the click had no effect within the timeout.
;-------------------------------------------------------------------------------
GoToShopFromHome(timeoutSeconds := 20) {
    global session, SHOP_TILE_X, SHOP_TILE_Y

    if (!FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true)) {
        LogWarn("GoToShopFromHome: Home screen not detected (Common_ShopButtonInMain missing)")
        return false
    }

    ; Tap once and wait. The same coordinates hit a shop item once the shop is
    ; open, so only tap again if Home is still showing after a long wait.
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    lastTap := 0
    Loop {
        if (lastTap = 0 || (A_TickCount - lastTap > 8000 && FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true))) {
            adbClick_wbb(SHOP_TILE_X, SHOP_TILE_Y)
            lastTap := A_TickCount
        }
        Delay(1)

        ; The Home "Shop" label is gone once the shop page is open.
        if (FindOrLoseImage("Common_ShopButtonInMain", 1, 0, , true)) {
            LogInfo("GoToShopFromHome: left Home screen, shop opened")
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
; NOTE: the needle checks below pass safeTime 0 on purpose. A safeTime >= 45
; makes FindOrLoseImage trigger the bot's stuck-restart (game restart + reload),
; so these loops use their own timeouts instead.
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
            LogInfo("ClaimShopDailyGift: shop loaded after " . failSafeTime . "s")
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
            LogInfo("ClaimShopDailyGift: no daily gift dot found, nothing to claim")
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
                LogInfo("ClaimShopDailyGift: daily gift claimed")
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

;-------------------------------------------------------------------------------
; RunShopTest - Manual test: Home -> Shop -> ESC -> Home. Started via
; "1.ahk --test-shop"; results go to Logs via LogInfo/LogWarn.
;-------------------------------------------------------------------------------
RunShopTest() {
    global session

    if (!GoToShopFromHome()) {
        LogWarn("RunShopTest: FAILED to open shop")
        return false
    }
    Delay(3)

    session.set("failSafe", A_TickCount)
    Loop {
        adbInputEvent("111") ; ESC
        Delay(2)
        if (FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true)) {
            LogInfo("RunShopTest: PASSED, back on Home")
            return true
        }
        if ((A_TickCount - session.get("failSafe")) // 1000 > 30) {
            LogWarn("RunShopTest: FAILED to return Home")
            return false
        }
    }
}
