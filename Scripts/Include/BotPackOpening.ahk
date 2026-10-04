; Pack selection and opening flow, gifts and hourglass opening

ensureMissionUserPrefsExist() {
    global session
    if(!doesMissionUserPrefsExist()) {
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        ; Click for hamburger menu and wait for profile
        Loop {
            adbClick(240, 494)
            if(FindOrLoseImage("Profile_UserNameArrowInSettingMenu", 0, failSafeTime)) {
                break
            } else {
                clickButton := FindOrLoseImage("Common_ColorChangeButton", 0, , 80)
                if(clickButton) {
                    StringSplit, pos, clickButton, `,  ; Split at ", "
                    adbClick(pos1, pos2)
                }
            }
            Delay(1)
            failSafeTime := (A_TickCount - failSafe) // 1000
        }

        FindImageAndClick("Profile_EditNameButtonIcon", 210, 140, , 200) ; Open profile/stats page and wait
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        ; Click for hamburger menu and wait for profile
        Loop {
            adbInputEvent("111") ;send ESC
            if(FindOrLoseImage("Profile_UserNameArrowInSettingMenu", 0, failSafeTime)) {
                break
            } else {
                clickButton := FindOrLoseImage("Common_ColorChangeButton", 0, , 80)
                if(clickButton) {
                    StringSplit, pos, clickButton, `,  ; Split at ", "
                    adbClick(pos1, pos2)
                }
            }
            Delay(1)
            failSafeTime := (A_TickCount - failSafe) // 1000
        }

    }
}

FindHourglassOpenConfirmation(tenPackOpening, failSafeTime) {
    if (tenPackOpening)
        return (FindOrLoseImage(67, 446, 83, 468, , "HourglassPack10", 0, failSafeTime) || FindOrLoseImage(45, 446, 60, 465, , "HourGlassAndPokeGoldPack10", 0, failSafeTime) || FindOrLoseImage("Pack_PokeGoldImageAfterOpenPackClick", 0, failSafeTime) || FindOrLoseImage(66, 447, 84, 465, , "PokeGoldPackNoHourglasses", 0, failSafeTime))

    return (FindOrLoseImage("Pack_HourglassImageAfterOpenPackClick", 0, failSafeTime) || FindOrLoseImage("Pack_HourglassAndPokeGoldImageAfterOpenPackClick", 0, failSafeTime) || FindOrLoseImage("Pack_PokeGoldImageAfterOpenPackClick", 0, failSafeTime) || FindOrLoseImage(66, 447, 84, 465, , "PokeGoldPackNoHourglasses", 0, failSafeTime))
}

FindHourglassOpenConfirmationClosed(tenPackOpening, failSafeTime) {
    if (tenPackOpening)
        return (FindOrLoseImage(67, 446, 83, 468, , "HourglassPack10", 1, failSafeTime) && FindOrLoseImage(45, 446, 60, 465, , "HourGlassAndPokeGoldPack10", 1, failSafeTime) && FindOrLoseImage("Pack_PokeGoldImageAfterOpenPackClick", 1, failSafeTime) && FindOrLoseImage(66, 447, 84, 465, , "PokeGoldPackNoHourglasses", 1, failSafeTime))

    return (FindOrLoseImage("Pack_HourglassImageAfterOpenPackClick", 1, failSafeTime) && FindOrLoseImage("Pack_HourglassAndPokeGoldImageAfterOpenPackClick", 1, failSafeTime) && FindOrLoseImage("Pack_PokeGoldImageAfterOpenPackClick", 1, failSafeTime) && FindOrLoseImage(66, 447, 84, 465, , "PokeGoldPackNoHourglasses", 1, failSafeTime))
}

WaitForPackPointButtonFromHome(clickX, clickY, context := "") {
    global session

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(DismissMainCloseAlertWindow(context)) {
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            continue
        }

        adbClick_wbb(clickX, clickY)
        Delay(0.5)
        if(FindOrLoseImage("Pack_PackPointButton", 0, failSafeTime))
            return true

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Points`n(" . failSafeTime . "/90 seconds)")
    }
}

;-------------------------------------------------------------------------------
; EnterFavouritePackFromHome - switch to favourites view in Home, click the
; pack once to enter the Points screen, then wait for Pack_PackPointButton.
;-------------------------------------------------------------------------------
EnterFavouritePackFromHome() {
    global session

    session.set("favEnteredFromHome", true)

    ; Skip favourites switch for packs already stable in Home.
    mainScreenPacks := session.get("mainScreenPackList")
    isStableInHome := false
    homePosition := ""
    if (IsObject(mainScreenPacks)) {
        for pos, packName in mainScreenPacks {
            if (packName = session.get("openPack")) {
                isStableInHome := true
                homePosition := pos
                break
            }
        }
    }

    if (!isStableInHome) {
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop {
            adbClick_wbb(265, 236)
            Delay(1)
            if (FindOrLoseImage(245, 146, 251, 153, , "FavouriteBooster", 0, failSafeTime))
                break
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            if (failSafeTime >= 30) {
                LogWarn("EnterFavouritePackFromHome: timed out waiting for FavouriteBooster", "ADB.txt")
                break
            }
        }
    }

    ; For stable Home packs, use the Home position (Left/Middle/Right).
    ; For favourite packs, use GetPackFavoriteHomeX (position within expansion).
    mapHomeX := {"Left":60, "Middle":140, "Right":215}
    if (isStableInHome) {
        favHomeX := mapHomeX[homePosition]
        if (favHomeX = "")
            favHomeX := 140
    } else if (IsFunc("GetPackFavoriteHomeX")) {
        favHomeX := GetPackFavoriteHomeX(session.get("openPack"))
    } else {
        favHomeX := 140
    }

    WaitForPackPointButtonFromHome(favHomeX, 203, "after fav pack select")
}

RecoverPackOpeningToMainIfNeeded(caller := "") {
    global session

    foundRecoveryScreen := false

    if (FindOrLoseImage("Common_AlertForAppCrachDuringOpenPack", 0, 0, , true)) {
        adbClick_wbb(139, 371)
        Delay(2)
        foundRecoveryScreen := true
    }

    if (!foundRecoveryScreen) {
        foundRecoveryScreen := FindOrLoseImage("Create_NintendoLink", 0, 0, , true)
        if (!foundRecoveryScreen)
            foundRecoveryScreen := FindOrLoseImage("Create_DownloadAlertWindow", 0, 0, , true)
        if (!foundRecoveryScreen)
            foundRecoveryScreen := FindOrLoseImage("Create_DownloadComplete", 0, 0, , true)
        if (!foundRecoveryScreen)
            foundRecoveryScreen := FindOrLoseImage("Create_CinematicBackground", 0, 0, , true)
        if (!foundRecoveryScreen)
            foundRecoveryScreen := FindOrLoseImage("Create_WelcomePopup", 0, 0, , true)
        if (!foundRecoveryScreen)
            foundRecoveryScreen := FindOrLoseImage("StartupErrorX", 0, 0, , true)
        if (!foundRecoveryScreen)
            foundRecoveryScreen := FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true)
    }

    if (!foundRecoveryScreen)
        return false

    LogInfo("Pack opening error recovery from " . caller . ": returning to selected pack screen", "Restart.txt")
    session.set("failSafe", A_TickCount)
    failSafeTime := 0

    Loop {
        if (FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true)) {
            GoToMain()
            return true
        }

        if (FindOrLoseImage("Common_AlertForAppCrachDuringOpenPack", 0, 0, , true)) {
            adbClick_wbb(139, 371)
        } else if (FindOrLoseImage("StartupErrorX", 0, 0, , true)) {
            adbClick_wbb(140, 439)
        } else if (FindOrLoseImage("Create_DownloadAlertWindow", 0, 0, , true)) {
            adbClick_wbb(203, 364)
        } else if (FindOrLoseImage("Create_DownloadComplete", 0, 0, , true)) {
            adbClick_wbb(140, 370)
        } else if (FindOrLoseImage("Create_NintendoLink", 0, 0, , true)) {
            adbClick_wbb(140, 460)
        } else if (FindOrLoseImage("Create_WelcomePopup", 0, 0, , true)) {
            adbClick_wbb(253, 506)
        } else if (FindOrLoseImage("Create_CinematicBackground", 0, 0, , true)) {
            adbClick_wbb(253, 506)
        } else {
            adbClick_wbb(140, 460)
        }

        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Recovering pack opening`n(" . failSafeTime . "/90 seconds)")
        if (failSafeTime > 90) {
            restartGameInstance("Stuck recovering pack opening error")
            return false
        }
    }
}

SelectPack(HG := false) {
    global session

    if(HG = "HGPack" || HG = "HGPack10")
        session.set("packOpeningRecoveryPack", HG)
    else
        session.set("packOpeningRecoveryPack", "")

    ; define constants
    mapPackX := {"Left":60, "Middle":140, "Right":215}
    mainScreenPackCoords := {"MegaBlaziken":mapPackX["Left"], "Parade":mapPackX["Middle"], "CrimsonBlaze":mapPackX["Right"]}

    HomeScreenAllPackY := 203
    PackScreenAllPackY := 320

    packx := getPackCoordXInHome()
    packy := HomeScreenAllPackY
    enteredPackScreenFromHome := false

    LogInfo("SelectPack: HG=" . HG . " packFavoriteSet=" . session.get("packFavoriteSet") . " isSkipSelectExpansion=" . session.get("isSkipSelectExpansion") . " openPack=" . session.get("openPack"), "ADB.txt")

    ; When favourite pack is set and we are coming from Home (not First boot),
    ; switch to the favourites view in Home before clicking the pack.
    ; Skip the switch for packs that are already stable in the Home screen
    ; (listed in mainScreenPackList).
    if (session.get("packFavoriteSet") && HG != "First") {
        mainScreenPacks := session.get("mainScreenPackList")
        isStableInHome := false
        homePosition := ""
        if (IsObject(mainScreenPacks)) {
            for pos, packName in mainScreenPacks {
                if (packName = session.get("openPack")) {
                    isStableInHome := true
                    homePosition := pos
                    break
                }
            }
        }
        if (!isStableInHome) {
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            Loop {
                adbClick_wbb(265, 236)
                Delay(1)
                if (FindOrLoseImage(245, 146, 251, 153, , "FavouriteBooster", 0, failSafeTime))
                    break
                failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
                if (failSafeTime >= 30) {
                    LogWarn("SelectPack: timed out waiting for FavouriteBooster in Home", "ADB.txt")
                    break
                }
            }
        }
        ; For stable Home packs, use the Home position (Left/Middle/Right).
        ; For favourite packs, use GetPackFavoriteHomeX (position within expansion).
        if (isStableInHome) {
            packx := mapPackX[homePosition]
            if (packx = "")
                packx := 140
        } else if (IsFunc("GetPackFavoriteHomeX")) {
            packx := GetPackFavoriteHomeX(session.get("openPack"))
        }
    }

    ensureMissionUserPrefsExist()
    InitPackOpening()
    if(HG = "First" && session.get("injectMethod") && session.get("loadedAccount") ){
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop {
            if(DismissMainCloseAlertWindow("Waiting for Points")) {
                failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
                continue
            }

            ; When favourite pack is set, the game boots directly into the
            ; Points screen. Don't click in Home, just wait for Points.
            if (!session.get("packFavoriteSet"))
                adbClick_wbb(packx, HomeScreenAllPackY)
            Delay(1)
            if(FindOrLoseImage("Pack_PackPointButton", 0, failSafeTime)) {
                break
            }
            else if(!renew && !getFC) {
                if(FindOrLoseImage("Common_AlertForAppCrachDuringOpenPack", 0)) {
                    adbClick_wbb(139, 371)
                }
            }
            else if(FindOrLoseImage("Create_TutorialUseResourceForOpenPack", 0)) {
                ;TODO hourglass tutorial still broken after injection
                Delay(3)
                adbClick_wbb(146, 441)
                Delay(3)
                adbClick_wbb(146, 441)
                Delay(3)
                adbClick_wbb(146, 441)
                Delay(3)

                FindImageAndClick("Create_TutorialPremiumPass", 168, 438, , 500, 5) ;stop at hourglasses tutorial 2
                Delay(1)

                adbClick_wbb(203, 436)
                FindImageAndClick("Create_InfoIconInStandByOpenPack", 180, 436, , 500) ;stop at hourglasses tutorial 2 180 to 203?
            }

            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            CreateStatusMessage("Waiting for Points`n(" . failSafeTime . "/90 seconds)")
        }
        enteredPackScreenFromHome := true
    }

    if (!enteredPackScreenFromHome)
        FindImageAndClick("Pack_PackPointButton", packx, packy, , 1000)

    if(!session.get("isSkipSelectExpansion")) {
        FindImageAndClick("Pack_ScrollInSelectExpansion", 248, 459, , 300)

        ; packs that can be opened after clicking A series
        session.get("packCoordinates")[session.get("openPack")].moveSeriesScreen()
        session.get("packCoordinates")[session.get("openPack")].expansionScreenDrag()

        packx := session.get("packCoordinates")[session.get("openPack")].getXPos()
        packy := session.get("packCoordinates")[session.get("openPack")].getYPos()

        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop{
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            CreateStatusMessage("Move pack:" . session.get("openPack") . "`n(" . failSafeTime . "/90 seconds)")

            adbClick_wbb(packx, packy)
            Delay(2)
            if(FindOrLoseImage("Pack_ScrollInSelectExpansion", 1, , , 1)) {
                break
            }
        }
        Delay(2)
        session.get("packCoordinates")[session.get("openPack")].additionalAction()
    }
    else if (session.get("packFavoriteSet")) {
        ; Favourite pack: already on the correct expansion screen.
        ; Nothing to do here. The pack selection click happens after
        ; FindPackStats() below, so we don't interfere with it.
    }

    if(HG = "First" && session.get("injectMethod") && session.get("loadedAccount") && !session.get("accountHasPackInfo")) {
        FindPackStats()
    }

    ; Favourite pack: now that FindPackStats is done (or skipped), click the
    ; specific pack within the expansion to select it. Only needed on cold
    ; boot (game boots with centre pack in foreground). When entering from
    ; Home favourites, the clicked pack is already in foreground.
    if (session.get("packFavoriteSet") && HG = "First" && !session.get("favEnteredFromHome")) {
        if (IsFunc("GetPackFavoritePointsX"))
            favPackX := GetPackFavoritePointsX(session.get("openPack"))
        else
            favPackX := 140
        if (favPackX != 140) {
            adbClick_wbb(favPackX, PackScreenAllPackY)
            Delay(1)
        }
    }

    if(HG = "Tutorial") {
        FindImageAndClick("Create_InfoIconInStandByOpenPack", 180, 436, , 500) ;stop at hourglasses tutorial 2 180 to 203?
    }
    else if(HG = "HGPack" || HG = "HGPack10") {
        tenPackOpening := (HG = "HGPack10")
        openPackCoord := session.get("packCoordinates")[session.get("openPack")]
        if (IsObject(openPackCoord))
            openPackCoord.tapPackPreviewUntilPointsGone()
        Delay(1)

        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop {
            if (RecoverPackOpeningToMainIfNeeded("SelectPackConfirmation")) {
                SelectPack(HG)
                return
            }
            if(FindHourglassOpenConfirmation(tenPackOpening, failSafeTime)) {
                break
            }else if(FindOrLoseImage("Pack_NotEnoughItemsForOpenPack", 0)) {
                session.set("cantOpenMorePacks", 1)
            }
            if(session.get("cantOpenMorePacks"))
                return
            openButtonX := tenPackOpening ? 70 : 161
            adbClick_wbb(openButtonX, 423)
            Delay(1)
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            statusText := tenPackOpening ? "Waiting for HourglassPack10" : "Waiting for HourglassPack3"
            CreateStatusMessage(statusText . "`n(" . failSafeTime . "/45 seconds)")
        }
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop {
            if (RecoverPackOpeningToMainIfNeeded("SelectPackConfirmationClosed")) {
                SelectPack(HG)
                return
            }
            if(FindHourglassOpenConfirmationClosed(tenPackOpening, failSafeTime)) {
                break
            }
            adbClick_wbb(205, 458)
            Delay(1)
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            CreateStatusMessage("Waiting for HourglassPack4`n(" . failSafeTime . "/45 seconds)")
        }
    } else {
        openPackCoord := session.get("packCoordinates")[session.get("openPack")]
        if (IsObject(openPackCoord))
            openPackCoord.tapPackPreviewUntilPointsGone()
        Delay(1)

        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        failsafeClickExecuted := false  ; Flag to track if failsafe click has been executed
        Loop {
            adbClick_wbb(151, 420)  ; open button
            if(FindOrLoseImage("Pack_AnimationToReadyOpenPack", 0, failSafeTime)) {
                break
            } else if(FindOrLoseImage("Pack_NotEnoughItemsForOpenPack", 0)) {
                session.set("cantOpenMorePacks", 1)
            } else if(FindOrLoseImage("Pack_HourglassImageAfterOpenPackClick", 0, 1) || FindOrLoseImage("Pack_HourglassAndPokeGoldImageAfterOpenPackClick", 0, 1)) {
                adbClick_wbb(205, 458)  ; Handle unexpected HG pack confirmation
            } else if(FindOrLoseImage("Common_AlertForAppCrachDuringOpenPack", 0)) {
                ; Handle restart caused due to network error
                adbClick_wbb(139, 371)
                if (session.get("injectMethod") && session.get("loadedAccount") && session.get("friended")) {
                    IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
                }
                LogInfo("[" . A_ScriptName . "] Stuck #1 in SelectPack.", "Restart.txt")
                restartGameInstance("Stuck at pack opening")
                return
            } else {
                adbClick_wbb(200, 451)  ; Additional fallback click
            }

            if(session.get("cantOpenMorePacks"))
                return

            Delay(0.1)
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            CreateStatusMessage("Waiting for Skip2`n(" . failSafeTime . "/45 seconds)")
        }
    }
}

PackOpening(tenPackOpening := false) {
    global session
    if (isTerminatePTCGPHelperApp()) {
        InitPackOpening()
    }
    recoveryPack := tenPackOpening ? "HGPack10" : session.get("packOpeningRecoveryPack")
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    failsafeClickExecuted := false
    Loop {
        if(recoveryPack != "" && RecoverPackOpeningToMainIfNeeded("PackOpening")) {
            SelectPack(recoveryPack)
            if(session.get("cantOpenMorePacks"))
                return
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            failsafeClickExecuted := false
            continue
        }
        ; 2nd+ pack: game may force Welcome Back missions tab while Waiting for Pack
        if(TryRecoverWelcomeBackMissionsAfterPack("PackOpening", recoveryPack)) {
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            failsafeClickExecuted := false
            continue
        }
        adbClick_wbb(146, 434)
        Delay(0.2)
        adbClick_wbb(170, 455)
        if(FindOrLoseImage("Pack_ReadyForOpenPack", 0, failSafeTime)) {
            break ;wait for pack to be ready to Trace and click skip
        } else if(FindOrLoseImage("Pack_NotEnoughItemsForOpenPack", 0)) {
            session.set("cantOpenMorePacks", 1)
        } else if(FindOrLoseImage("Pack_HourglassImageAfterOpenPackClick", 0, 1) || FindOrLoseImage("Pack_HourglassAndPokeGoldImageAfterOpenPackClick", 0, 1)) {
            adbClick_wbb(205, 453) ; handle unexpected no packs available
        } else if(FindOrLoseImage("Pack_GetItemDialogAfterOpenPack", 0)){
            adbInputEvent("111")
            Delay(2)
        } else {
            adbClick_wbb(239, 492)
        }

        ; Execute failsafe click only once after 10 seconds to try to select Floating Pack
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        if (failSafeTime >= 10 && !failsafeClickExecuted) {
            if (FindOrLoseImage("Pack_PackPointButton", 0)) {
                CreateStatusMessage("Trying to click floating pack...")
                Sleep, 3000
                adbClick_wbb(151, 245) ; if pack is floating/glitched
                failsafeClickExecuted := true
            }
        }

        if(session.get("cantOpenMorePacks"))
            return

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Pack`n(" . failSafeTime . "/45 seconds)")
        if(failSafeTime > 45){
            RemoveFriends()
            if(session.get("injectMethod") && session.get("loadedAccount") && session.get("friended")) {
                IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
            }
            restartGameInstance("Stuck at Pack")
        }
    }

    if(session.get("setSpeed") > 1) {
        FindImageAndClick("Common_SpeedModMenuButton", 18, 109, , 2000)
        FindImageAndClick(GetSpeedModNeedle(1), GetSpeedModClickX(1), GetSpeedModClickY(1))
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)
    }
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbSwipe_wbb(adbSwipeParams)
        Sleep, 100
        if (FindOrLoseImage("Pack_ReadyForOpenPack", 1, failSafeTime)){
            if(session.get("setSpeed") > 1) {
                if(session.get("setSpeed") = 3) {
                    FindImageAndClick("Common_SpeedModMenuButton", 18, 109, , 2000)
                    FindImageAndClick(GetSpeedModNeedle(3), GetSpeedModClickX(3), GetSpeedModClickY(3))
                }
            }
            adbClick_wbb(51, 292)
            break
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Trace`n(" . failSafeTime . "/45 seconds)")
        Delay(1)
    }

    resultNeedle := tenPackOpening ? "Gift_ResultAfterOpenPack" : "Pack_ResultAfterOpenPack"
    FindImageAndClick(resultNeedle, 252, 505, 5, 25) ;skip through cards until results opening screen

    CheckPack()
    SetLastPackPulledNow()
    ; A completed pack is forward progress even when the overall account task
    ; runs longer than the monitor threshold.
    writeLastActivityEpoch(session.get("scriptName"))

    if(!CardDetection_HasPendingGodPack() && !session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum"))
        return

    ;FindImageAndClick("Pack_SkipButtonAfterOpenPack", 146, 494) ;click on next until skip button appears

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        Delay(4)
        if(FindOrLoseImage("Pack_SkipButtonAfterOpenPack", 0, failSafeTime)) {
            adbClick_wbb(247, 500)
            Delay(1)
        } else if(FindOrLoseImage("Pack_NextButtonAfterOpenPack", 0, failSafeTime)) {
            adbClick_wbb(146, 489) ;146, 494
            Delay(1)
        } else if(FindOrLoseImage("Next2", 0, failSafeTime)) {
            adbClick_wbb(146, 489) ;146, 494
            Delay(1)
        } else if(FindOrLoseImage("Pack_BackButtonInSelectPackScreen", 0, failSafeTime)) {
            break
        } else if(FindOrLoseImage("Create_TutorialUseResourceForOpenPack", 0, failSafeTime)) {
            break
        } else {
            adbClick_wbb(146, 489) ;146, 494
            Delay(1)
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Home`n(" . failSafeTime . "/45 seconds)")
        if(failSafeTime > 45)
            restartGameInstance("Stuck at Home")
    }

    CardDetection_FlushPendingGodPack()
}

HourglassOpening(HG := false, NEIRestart := true, tenPackOpening := false) {
    global botConfig, session
    if (isTerminatePTCGPHelperApp()) {
        InitPackOpening()
    }
    recoveryPack := tenPackOpening ? "HGPack10" : "HGPack"
    if(!HG) {
        Delay(3)
        adbClick_wbb(146, 441) ; 146 440
        Delay(3)
        adbClick_wbb(146, 441)
        Delay(3)
        adbClick_wbb(146, 441)
        Delay(3)

        FindImageAndClick("Create_TutorialPremiumPass", 168, 430, , 650, 5) ;stop at hourglasses tutorial 2
        Delay(1)

        adbClick_wbb(203, 436) ; 203 436

        if(session.get("packMethod")) {
            PackMethod_RenewFriends()
            SelectPack("Tutorial")
        }
        else {
            FindImageAndClick("Create_InfoIconInStandByOpenPack", 180, 436, , 500) ;stop at hourglasses tutorial 2 180 to 203?

            if(session.get("cantOpenMorePacks"))
                return
        }
    }
    if(!session.get("packMethod")) {
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        failsafeClickExecuted := false
        recoveredPackOpening := false
        Loop {
            if (RecoverPackOpeningToMainIfNeeded("HourglassOpeningConfirmation")) {
                SelectPack(recoveryPack)
                if(session.get("cantOpenMorePacks"))
                    return
                recoveredPackOpening := true
                break
            }
            if(TryRecoverWelcomeBackMissionsAfterPack("HourglassOpening", recoveryPack)) {
                session.set("failSafe", A_TickCount)
                failSafeTime := 0
                failsafeClickExecuted := false
                continue
            }
            if(FindHourglassOpenConfirmation(tenPackOpening, failSafeTime)) {
                break
            }else if(FindOrLoseImage("Pack_NotEnoughItemsForOpenPack", 0)) {
                session.set("cantOpenMorePacks", 1)
            }
            if(session.get("cantOpenMorePacks"))
                return

            ; Execute failsafe click only once after 10 seconds to try to click floating pack
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            if (failSafeTime >= 10 && !failsafeClickExecuted) {
                if (FindOrLoseImage("Pack_PackPointButton", 0)) {
                    CreateStatusMessage("Trying to click floating pack...")
                    Sleep, 3000
                    adbClick_wbb(151, 250) ; if pack is floating/glitched
                    failsafeClickExecuted := true
                }
            }

            if(failSafeTime >= 45) {
                restartGameInstance("Stuck waiting for HourglassPack")
                return
            }
            openButtonX := tenPackOpening ? 70 : 146
            adbClick_wbb(openButtonX, 434)
            Delay(1)
            statusText := tenPackOpening ? "Waiting for HourglassPack10" : "Waiting for HourglassPack"
            CreateStatusMessage(statusText . "`n(" . failSafeTime . "/45 seconds)")
        }
        if(!recoveredPackOpening) {
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            Loop {
                if (RecoverPackOpeningToMainIfNeeded("HourglassOpeningConfirmationClosed")) {
                    SelectPack(recoveryPack)
                    if(session.get("cantOpenMorePacks"))
                        return
                    recoveredPackOpening := true
                    break
                }
                if(FindHourglassOpenConfirmationClosed(tenPackOpening, failSafeTime)) {
                    break
                }
                adbClick_wbb(205, 458)
                Delay(1)
                failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
                CreateStatusMessage("Waiting for HourglassPack2`n(" . failSafeTime . "/45 seconds)")
            }
        }
    }
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(RecoverPackOpeningToMainIfNeeded("HourglassOpeningPackReady")) {
            SelectPack(recoveryPack)
            if(session.get("cantOpenMorePacks"))
                return
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            continue
        }
        adbClick_wbb(146, 434)
        Delay(1)
        adbClick_wbb(170, 455)
        if(FindOrLoseImage("Pack_ReadyForOpenPack", 0, failSafeTime))
            break ;wait for pack to be ready to Trace and click skip
        else
            adbClick_wbb(239, 497)

        if(session.get("cantOpenMorePacks"))
            return

        if(FindOrLoseImage("Common_ShopButtonInMain", 0, failSafeTime)){
            SelectPack(recoveryPack)
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
        }

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Pack`n(" . failSafeTime . "/45 seconds)")
        if(failSafeTime > 45) {
            if(session.get("injectMethod") && session.get("loadedAccount") && session.get("friended")) {
                IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
            }
            restartGameInstance("Stuck at Pack")
        }
    }

    if(session.get("setSpeed") > 1) {
        FindImageAndClick("Common_SpeedModMenuButton", 18, 109, , 2000)
        FindImageAndClick(GetSpeedModNeedle(1), GetSpeedModClickX(1), GetSpeedModClickY(1))
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)
    }
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbSwipe_wbb(adbSwipeParams)
        Sleep, 100
        if (FindOrLoseImage("Pack_ReadyForOpenPack", 1, failSafeTime)){
            if(session.get("setSpeed") > 1) {
                if(session.get("setSpeed") = 3) {
                    FindImageAndClick("Common_SpeedModMenuButton", 18, 109, , 2000)
                    FindImageAndClick(GetSpeedModNeedle(3), GetSpeedModClickX(3), GetSpeedModClickY(3))
                }
            }
            adbClick_wbb(51, 297)
            break
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Trace`n(" . failSafeTime . "/45 seconds)")
        Delay(1)
    }

    resultNeedle := tenPackOpening ? "Gift_ResultAfterOpenPack" : "Pack_ResultAfterOpenPack"
    FindImageAndClick(resultNeedle, 252, 505, 5, 25) ;skip through cards until results opening screen

    CheckPack()
    SetLastPackPulledNow()
    ; A completed pack is forward progress even when the overall account task
    ; runs longer than the monitor threshold.
    writeLastActivityEpoch(session.get("scriptName"))

    if(!CardDetection_HasPendingGodPack() && !session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum"))
        return

    ;FindImageAndClick("Pack_SkipButtonAfterOpenPack", 146, 494) ;click on next until skip button appears

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        Delay(4)
        if(FindOrLoseImage("Pack_SkipButtonAfterOpenPack", 0, failSafeTime)) {
            adbClick_wbb(239, 497)
            Delay(1)
        } else if(FindOrLoseImage("Pack_NextButtonAfterOpenPack", 0, failSafeTime)) {
            adbClick_wbb(146, 494) ;146, 494
            Delay(1)
        } else if(FindOrLoseImage("Next2", 0, failSafeTime)) {
            adbClick_wbb(146, 494) ;146, 494
            Delay(1)
        } else if(FindOrLoseImage("Pack_BackButtonInSelectPackScreen", 0, failSafeTime)) {
            break
        } else {
            adbClick_wbb(146, 494) ;146, 494
            Delay(1)
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for ConfirmPack`n(" . failSafeTime . "/45 seconds)")
        if(failSafeTime > 45)
            restartGameInstance("Stuck at ConfirmPack")
    }

    CardDetection_FlushPendingGodPack()
}

ReceiveGiftExtended() {
    global session, receivedGiftOnly

    if (HasFlagInMetadata(session.get("accountFileName"), "R"))
        return false

    ; Reach gift screen with a timeout to avoid endless loops on UI desync.
    foundClaimable := false
    foundClaimedAll := false
    minClaimableWaitSeconds := 5
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(FindOrLoseImage("Common_ShopButtonInMain", 0)) {
            adbClick_wbb(247, 93)
            Delay(4)
        }

        if(FindOrLoseImage("Gift_Claimable", 0, 0, 25)) {
            foundClaimable := true
            break
        }

        elapsedSeconds := (A_TickCount - session.get("failSafe")) // 1000
        if(elapsedSeconds >= minClaimableWaitSeconds && FindOrLoseImage("Gift_ClaimedAll", 0, 0, 25)) {
            foundClaimedAll := true
            break
        }

        failSafeTime := elapsedSeconds
        if(failSafeTime > 45)
            break
    }
    failSafeTime := 0
    if(!foundClaimable) {
        if(foundClaimedAll || (elapsedSeconds >= minClaimableWaitSeconds && FindOrLoseImage("Gift_ClaimedAll", 0, 0, 25)))
            return false
        return false
    }

    maxClaimAttempts := 12
    claimConfirmed := false
    Loop, %maxClaimAttempts% {
        adbClick(212, 427)
        Delay(3)
        if (FindOrLoseImage("Gift_ReceivedWindowRightBorder", 0, 0, 25)) {
            claimConfirmed := true
            adbInputEvent("111")
            Delay(2)
            break
        }
        if(FindOrLoseImage("Pack_ReadyForOpenPack", 1, 0)){
            claimConfirmed := true
            adbInputEvent("111")
            Delay(2)
            break
        }
    }

    if(!claimConfirmed)
        return false

    Delay(1)

    receivedGiftOnly := true
    return true
}

HandleGiftedPacksAfterReceiveGift() {
    global session

    handledGiftPacks := 0
    maxGiftPacks := 20
    sawReceivedWindow := false
    rewardSetHandled := false

    session.set("failSafe", A_TickCount)
    failSafeTime := 0

    Loop {
        if (rewardSetHandled || !FindOrLoseImage("Gift_Claimable", 0, 1)) {
            if(FindOrLoseImage("Gift_ClaimedAll", 0, 1)) {
                adbInputEvent("111")
                Delay(1)
                break
            }
        }

        if(FindOrLoseImage("Gift_ReceivedWindowRightBorder", 0, 1)) {
            adbInputEvent("111")
            Delay(1)
            sawReceivedWindow := true
            rewardSetHandled := true
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            continue
        }

        if(FindOrLoseImage("Pack_ReadyForOpenPack", 0, 1)) {
            HandleSingleGiftPackOpening()
            handledGiftPacks++
            rewardSetHandled := true

            if(handledGiftPacks >= maxGiftPacks)
                break

            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            continue
        }

        if(FindOrLoseImage("Pack_SkipButtonAfterOpenPack", 0, 1)) {
            adbClick_wbb(247, 500)
        } else if(FindOrLoseImage("Pack_NextButtonAfterOpenPack", 0, 1) || FindOrLoseImage("Next2", 0, 1)) {
            adbClick_wbb(146, 489)
        } else if(FindOrLoseImage("Pack_ResultAfterOpenPack", 0, 1)) {
            adbClick_wbb(247, 500)
        } else {
            adbClick_wbb(146, 489)
        }

        Delay(1)

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage((sawReceivedWindow ? "Finalizing gifts" : "Handling gifted packs") . "`n(" . failSafeTime . "/90 seconds)")
        if(failSafeTime > 90)
            break
    }
}

SetOpenGiftSpeed(targetSpeed) {
    if(targetSpeed != 1 && targetSpeed != 2 && targetSpeed != 3)
        return false

    SetOpenGiftSpeedByButtons(targetSpeed)

    return true
}

SetOpenGiftSpeedByButtons(targetSpeed) {
    FindImageAndClick("Common_SpeedModMenuButton", 18, 109, , 2000)
    if(targetSpeed = 1)
        FindImageAndClick(GetSpeedModNeedle(1), GetSpeedModClickX(1), GetSpeedModClickY(1))
    else if(targetSpeed = 3)
        FindImageAndClick(GetSpeedModNeedle(3), GetSpeedModClickX(3), GetSpeedModClickY(3))
    else
        FindImageAndClick(GetSpeedModNeedle(2), GetSpeedModClickX(2), GetSpeedModClickY(2))

    Delay(1)
    adbClick_wbb(51, 297)
    Delay(1)
    return true
}

HandleSingleGiftPackOpening() {
    global session, adbSwipeParams

    session.set("openedGiftPack", true)

    if(session.get("setSpeed") > 1) {
        SetOpenGiftSpeed(1)
    }

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbSwipe_wbb(adbSwipeParams)
        Sleep, 100
        ; Confirm swipe by requiring both ready markers to stay gone for a short window.
        if(FindOrLoseImage("Pack_ReadyForOpenPack", 1, failSafeTime)) {
            swipeConfirmed := true
            Loop, 4 {
                Sleep, 150
                if(FindOrLoseImage("Pack_ReadyForOpenPack", 0, 0, 20, 1)) {
                    swipeConfirmed := false
                    break
                }
            }

            if(swipeConfirmed) {
                if(session.get("setSpeed") > 1) {
                    SetOpenGiftSpeed(session.get("setSpeed"))
                }
                break
            }
        }

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Opening gifted pack`n(" . failSafeTime . "/45 seconds)")
        if(failSafeTime > 45) {
            if(session.get("setSpeed") > 1) {
                SetOpenGiftSpeed(session.get("setSpeed"))
            }
            restartGameInstance("Stuck at gifted pack swipe")
            return
        }
    }

    FindImageAndClick("Gift_ResultAfterOpenPack", 252, 505, 5, 25)

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(FindOrLoseImage("Gift_ReceivedWindowRightBorder", 0, 1)) {
            break
        } else if(FindOrLoseImage("Pack_ReadyForOpenPack", 0, 1)) {
            break
        } else if(FindOrLoseImage("Create_SwipeForRegisterDexIcon", 0, 1)) {
            break
        } else if(FindOrLoseImage("Pack_SkipButtonAfterOpenPack", 0, 1)) {
            adbClick_wbb(247, 500)
        } else if(FindOrLoseImage("Pack_NextButtonAfterOpenPack", 0, 1) || FindOrLoseImage("Next2", 0, 1)) {
            adbClick_wbb(146, 489)
        } else {
            adbClick_wbb(146, 489)
        }

        Delay(1)

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Advancing gifted pack`n(" . failSafeTime . "/45 seconds)")
        if(failSafeTime > 45)
            break
    }

    writeLastActivityEpoch(session.get("scriptName"))
}
