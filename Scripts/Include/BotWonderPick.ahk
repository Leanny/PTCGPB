; Wonder pick flow

; Wonder Pick reveals can show the first-time card-dex register tutorial.
; Skip dismisses it; no swipe needed.
TryWonderPickDexSwipeRegister() {
    global session

    if (!FindOrLoseImage("Create_SwipeForRegisterDexIcon", 0, 0, 20, 1))
        return false

    CreateStatusMessage("WonderPick: skip card dex tutorial...")
    adbClick_wbb(239, 497)
    Delay(1)
    session.set("failSafe", A_TickCount)
    return true
}

DoWonderPickOnly() {
    global session

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    pickAlreadyRevealed := false

    if (isTerminatePTCGPHelperApp()) {
        InitPackOpening()
    }

    SetGameSpeed(1)

    Loop {
        if (TryWonderPickDexSwipeRegister()) {
            pickAlreadyRevealed := true
            break
        }
        adbClick_wbb(30, 390) ; first wonderpick slot
        adbClick_wbb(250, 460) ; backup, second wonderpick slot
        if(FindOrLoseImage("WonderPick_NoEnergy", 0, failSafeTime)) {
            ; todo: this needs to be fixed for other languages
            Sleep, 2000
            CreateStatusMessage("No WonderPick Energy left!",,,, false)
            Sleep, 2000
            adbClick_wbb(137, 505)
            Sleep, 2000
            adbClick_wbb(35, 515)
            Sleep, 4000
            SetWonderPickMetadataFlag()
            return
        }
        if(FindOrLoseImage("WonderPick_WonderPickButtonInHome", 1, failSafeTime)) {
            if(FindOrLoseImage("WonderPick_EnergyStatusAfterSelect", 0, failSafeTime)){
                adbClick_wbb(198, 456)
                Delay(3)
                SetGameSpeed(3)
            }
            if(FindOrLoseImage("WonderPick_SelectCards", 0, failSafeTime))
                break
        }
        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for WonderPick`n(" . failSafeTime . "/45 seconds)")
    }
    SetGameSpeed(3)

    if (!pickAlreadyRevealed) {
        Sleep, 300
        if(botConfig.get("slowMotion"))
            Sleep, 3000
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop {
            if (TryWonderPickDexSwipeRegister()) {
                pickAlreadyRevealed := true
                break
            }
            adbClick_wbb(183, 350) ; click card
            if(FindOrLoseImage("WonderPick_SelectCards", 1, failSafeTime)) {
                break
            }
            Delay(1)
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            CreateStatusMessage("Waiting for Card`n(" . failSafeTime . "/45 seconds)")
        }
    }
    session.set("failSafe", A_TickCount)
    ;TODO thanks and wonder pick 5 times for missions
    TryWonderPickDexSwipeRegister()
    GoToMain()
    result := EvaluatePack()
    if (result) {
        LogToCardDatabase(result)
    }
    SetWonderPickMetadataFlag()
}

DoWonderPick() {
    global session

    FindImageAndClick("Common_ShopButtonInMain", 40, 515) ;click until at main menu

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(FindOrLoseImage("WonderPick_WonderPickButtonInHome", 0, failSafeTime))
            break
        else if(FindOrLoseImage("Common_PopupXButtonInMain", 0, , , true)){
            adbClick_wbb(137, 480)
        }
        else
            adbClick_wbb(59, 429)
        Delay(1)
    }

    DoWonderPickOnly()

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        ; todo: x check
        adbClick(261, 478)
        Sleep, 1000
        if FindOrLoseImage("Mission_ActivatedBeginnerMissionTabButton", 0, failSafeTime)
            break
        else if FindOrLoseImage("Mission_GoToDexButtonIcon", 0, failSafeTime)
            break
        else if FindOrLoseImage("Mission_DailyMissionImage", 0, failSafeTime)
            break
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
    }

    ;FindImageAndClick("WPMission", 150, 286, , 1000)
    FindImageAndClick("Mission_FirstWonderpickMissionIconInDetails", 150, 286, , 1000)
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        Delay(1)
        adbClick_wbb(139, 424)
        Delay(1)
        clickButton := FindOrLoseImage("Common_ColorChangeButton", 0, failSafeTime, 80)
        if(clickButton) {
            adbClick_wbb(110, 369)
        }
        else if(FindOrLoseImage("Common_ShopButtonInMain", 1, failSafeTime)){
            GoToMain()
            break
        }
        else if(FindOrLoseImage("Common_PopupXButtonInMain", 0, , , true)){
            adbClick_wbb(137, 480)
            Delay(1)
        }
        else
            break
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for WonderPick`n(" . failSafeTime . "/45 seconds)")
    }
    return true
}
