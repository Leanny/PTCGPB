; New account tutorial and start-up popups

DoTutorial() {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig, session

    session.set("creationDate", A_Now)

    FindImageAndClick("Create_CountryComboBoxButton", 143, 370) ;select month and year and click

    Delay(3)
    adbClick_wbb(80, 400)
    Delay(3)

    tutorialLanguage := Trim(session.get("language"))
    if (tutorialLanguage = "") {
        ; New accounts have no metadata yet, so read the active game's language
        if (EnsurePTCGPBHelperInstalled()) {
            tutorialLanguage := adbWriteRaw("/data/ptcgp/ptcgpb lang", true)
            tutorialLanguage := Trim(StrReplace(tutorialLanguage, "`r"), "`n`t ")
            if (RegExMatch(tutorialLanguage, "i)^[a-z][a-z0-9_-]{0,15}$"))
                session.set("language", tutorialLanguage)
            else
                tutorialLanguage := ""
        }
    }
    StringLower, tutorialLanguage, tutorialLanguage
    isYearInFront := (tutorialLanguage = "ja" || tutorialLanguage = "ko" || tutorialLanguage = "zh")
    if (isYearInFront) {
        ; JP/KR display the month picker in the opposite order.
        Random, monthScrollCount, 4, 7
        Loop, %monthScrollCount% {
            adbSwipe_wbb("100 707 100 903 150")
            Delay(3)
        }
    }

    adbClick_wbb(80, 375)
    Delay(3)
    session.set("failSafe", A_TickCount)
    failSafeTime := 0

    Loop {
        Delay(3)
        if(FindImageAndClick("Create_SelectedYear", , , , , 1, failSafeTime))
            break
        Delay(3)
        adbClick_wbb(142, 159)
        Delay(3)
        adbClick_wbb(80, 400)
        Delay(3)
        adbClick_wbb(80, 375)
        Delay(3)
        adbClick_wbb(82, 422)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Year`n(" . failSafeTime . "/45 seconds)")
    } ;select month and year and click

    adbClick_wbb(200, 400)
    Delay(3)

    if (!isYearInFront) {
        ; Other languages display the year picker in the opposite order.
        Random, yearScrollCount, 4, 7
        Loop, %yearScrollCount% {
            adbSwipe_wbb("389 707 389 903 150")
            Delay(3)
        }
    }
    adbClick_wbb(200, 375)
    Delay(3)
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop { ;select month and year and click
        Delay(3)
        if(FindImageAndClick("Create_SelectedMonth", , , , , 1, failSafeTime))
            break
        Delay(3)
        adbClick_wbb(142, 159)
        Delay(3)
        adbClick_wbb(142, 159)
        Delay(3)
        adbClick_wbb(200, 400)
        Delay(3)
        adbClick_wbb(200, 375)
        Delay(3)
        adbClick_wbb(142, 159)
        Delay(3)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Month`n(" . failSafeTime . "/45 seconds)")
    } ;select month and year and click

    Delay(3)
    FindImageAndClick("Create_BirthConfirmCancelButton", 140, 474, , 1000)

    ;wait date confirmation screen while clicking ok

    FindImageAndClick("Create_TosOpenButton", 203, 371, , 1000) ;wait to be at the tos screen while confirming birth

    FindImageAndClick("Create_TosCloseButton", 139, 299, , 1000) ;wait for tos while clicking it

    FindImageAndClick("Create_TosOpenButton", 142, 486, , 1000) ;wait to be at the tos screen and click x

    FindImageAndClick("Common_PopupXButtonInMain", 142, 339, , 1000) ;wait to be at the tos screen

    FindImageAndClick("Create_TosOpenButton", 142, 486, , 1000) ;wait to be at the tos screen, click X

    Delay(3)
    adbClick_wbb(261, 374)

    Delay(3)
    adbClick_wbb(261, 406)

    Delay(3)
    adbClick_wbb(145, 484)

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(FindOrLoseImage("Create_SignupNotification", 0,failSafeTime)) {
            ; notification flow
            adbClick(138, 434)
            Sleep, 1000
            adbClick(136, 350)
            Sleep, 1000
            adbClick(136, 350)
            Delay(1)
        }
        if(FindOrLoseImage("Create_SignupsDataSharing", 0, failSafeTime)) {
            adbClick(82, 287)
            Sleep, 1000
            adbClick(80, 355)
            Sleep, 100
            adbClick(90, 425)
            Sleep, 100
            adbClick(141, 484)
            Delay(1)
        }
        if(FindImageAndClick("Create_BeginNewAccountButton", 145, 484, , , 2, failSafeTime)) ;wait to be at create save data screen while clicking
            break
        Delay(1)
        adbClick_wbb(261, 406)
        if(FindImageAndClick("Create_BeginNewAccountButton", 145, 484, , , 2, failSafeTime)) ;wait to be at create save data screen while clicking
            break
        Delay(1)
        adbClick_wbb(261, 374)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Save`n(" . failSafeTime . "/45 seconds)")
    }

    Delay(1)

    adbClick_wbb(143, 348)

    Delay(1)

    failSafeTime := 0
    match := ""
    Loop {
        if(FindOrLoseImage("Create_NintendoLink", 0, failSafeTime)) {
            match :="Create_NintendoLink"
            break
        }
        if(FindOrLoseImage("Create_NintendoLink2", 0, failSafeTime)) {
            match :="Create_NintendoLink2"
            break
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Nintendo Link`n(" . failSafeTime . "/45 seconds)")
    }
    Delay(1)
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(FindOrLoseImage(match, 0, failSafeTime)){
            adbClick_wbb(140, 460)
            Loop {
                Delay(1)
                if(FindOrLoseImage(match, 1, failSafeTime)){
                    adbClick_wbb(140, 380) ; click ok on the interrupted while opening pack prompt
                    break
                }
                failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            }
        } else if(FindOrLoseImage("Create_DownloadAlertWindow", 0, failSafeTime)){
            adbClick_wbb(203, 364)
        } else if(FindOrLoseImage("Create_DownloadComplete", 0, failSafeTime)){
            adbClick_wbb(140, 370)
        } else if(FindOrLoseImage("Create_CinematicBackground", 0, failSafeTime)){
            break
        }
        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
    }

    if(session.get("setSpeed") = 3){
        SetGameSpeed(1)
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)
    }

    FindImageAndClick("Create_WelcomePopup", 253, 506, , 110) ;click through cutscene until welcome page

    if(session.get("setSpeed") = 3){
        SetGameSpeed(3)
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)
    }
    FindImageAndClick("Create_NameInputIcon", 189, 438) ;wait for name input screen
    FindImageAndClick("Create_DeactivatedOKButton", 139, 257) ;wait for name input screen

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if (botConfig.get("AccountName") != "ERROR" && botConfig.get("AccountName") != "") {
            Random, randomNum, 1, 500 ; Generate random number from 1 to 500
            username := botConfig.get("AccountName") . "-" . randomNum
            username := SubStr(username, 1, 14)  ; max character limit
            LogDebug("Using AccountName: " . username)
        } else {
            fileName := A_ScriptDir . "\..\usernames.txt"
            if(FileExist(fileName))
                name := ReadFile("usernames")
            else
                name := ReadFile("usernames_default")

            Random, randomIndex, 1, name.MaxIndex()
            username := name[randomIndex]
            username := SubStr(username, 1, 14)  ; max character limit
            LogDebug("Using random username: " . username)
        }

        adbInput(username)
        Delay(1)
        if(FindImageAndClick("Create_PackReturnButtonIcon", 185, 372, , , 10))
            break
        adbClick_wbb(90, 370)
        Delay(1)
        adbClick_wbb(139, 254) ; 139 254 194 372
        Delay(1)
        adbClick_wbb(139, 254)
        Delay(1)
        EraseInput() ; incase the random pokemon is not accepted
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("In failsafe for Trace. " . failSafeTime . "/45 seconds")
        if(failSafeTime > 45)
            restartGameInstance("Stuck at name")
    }

    Delay(1)

    adbClick_wbb(140, 424)

    FindImageAndClick("Pack_ReadyForOpenPack", 140, 424) ;wait for pack to be ready  to trace
    if(session.get("setSpeed") > 1) {
        SetGameSpeed(1)
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)
    }
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbSwipe_wbb(adbSwipeParams)
        Sleep, 100
        if(FindOrLoseImage("Pack_ReadyForOpenPack", 1, failSafeTime)){
            if(session.get("setSpeed") > 1) {
                if(session.get("setSpeed") = 3) {
                    SetGameSpeed(3) ; click 3x
                }
            }
            adbClick_wbb(51, 297)
            break
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Pack`n(" . failSafeTime . "/45 seconds)")
    }

    FindImageAndClick("Create_SwipeForRegisterDexIcon", 140, 375) ;click through cards until needing to swipe up
    if(session.get("setSpeed") > 1) {
        SetGameSpeed(1)
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)
    }
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbSwipe_wbb("266 770 266 355 60")
        Sleep, 100
        if(FindOrLoseImage("Create_ConfirmRegisteredCard", 0, failSafeTime)){
            if(session.get("setSpeed") > 1) {
                SetConfiguredGameSpeed()
            }
            adbClick_wbb(51, 297)
            break
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for swipe up for " . failSafeTime . "/45 seconds")
        Delay(1)
    }

    Delay(1)
    adbClick_wbb(204, 371)

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbClick_wbb(137, 365)
        Delay(1)
        adbClick_wbb(137, 480)
        Delay(1)
        if(FindOrLoseImage("Create_MustClickMissionBackground", 0, failSafeTime)){
            break
        } else if(FindOrLoseImage("Create_DownloadAlertWindow", 0, failSafeTime)){
            adbClick_wbb(203, 364)
        }
    }

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        Delay(1)
        adbClick_wbb(247, 472)
        Delay(1)
        if(FindOrLoseImage("Create_TutorialPackOpenNotifyIcon", 0, failSafeTime)) {
            break
        }
        adbClick_wbb(90, 260)
        adbClick_wbb(140, 400)
        adbClick_wbb(137, 340)
        Delay(3)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for pack notification " . failSafeTime . "/45 seconds")
    }

    FindImageAndClick("Create_TutorialPackOpenNotifyIcon", 145, 194) ;click on packs. stop at booster pack tutorial

    Delay(3)
    adbClick_wbb(142, 436)
    Delay(3)
    adbClick_wbb(142, 436)
    Delay(3)
    adbClick_wbb(142, 436)
    Delay(3)
    adbClick_wbb(142, 436)

    FindImageAndClick("Pack_ReadyForOpenPack", 239, 497) ;wait for pack to be ready  to Trace
    if(session.get("setSpeed") > 1) {
        SetGameSpeed(1)
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)
    }
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbSwipe_wbb(adbSwipeParams)
        Sleep, 100
        if(FindOrLoseImage("Pack_ReadyForOpenPack", 1, failSafeTime)){
            if(session.get("setSpeed") > 1) {
                if(session.get("setSpeed") = 3) {
                    SetGameSpeed(3)
                }
            }
            adbClick_wbb(51, 297)
            break
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Pack`n(" . failSafeTime . "/45 seconds)")
        Delay(1)
    }

    FindImageAndClick("Pack_ResultAfterOpenPack", 252, 505, 5, 50) ;skip through cards until results opening screen

    FindImageAndClick("Pack_SkipButtonAfterOpenPack", 146, 496) ;click on next until skip button appears

    FindImageAndClick("Pack_NextButtonAfterOpenPack", 239, 497, , , 2)

    FindImageAndClick("Create_UnlockedWonerPickIconInLevelUp", 146, 494) ;click on next until skip button appearsstop at hourglasses tutorial

    Delay(3)

    adbClick_wbb(140, 358)

    FindImageAndClick("Common_ShopButtonInMain", 146, 444) ;click until at main menu

    ; New needle & search region 11.1.2025 kevinnnn
    FindImageAndClick("Create_CardImageInTutorialWPFirstScreen", 79, 411)

    FindImageAndClick("Create_WPItemBottomBorder", 190, 437) ; click through tutorial

    Delay(2)

    adbClick_wbb(202, 347) ; select Wonder Pick item to open Bonus Pick confirm
    Delay(2)

    ; Bonus Pick confirm (No cost / OK). Wonder4 selection needle often never matches on current UI.
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbClick_wbb(208, 461) ; OK
        Delay(1)
        if(FindOrLoseImage("Create_TitleBottomBorderInWPSelectCard", 0, failSafeTime))
            break
        ; Dialog may not have opened yet — retry select
        adbClick_wbb(202, 347)
        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Confirming WonderPick`n(" . failSafeTime . "/45 seconds)")
    }

    if(session.get("setSpeed") = 3) ;time the animation
        Sleep, 1500
    else
        Sleep, 2500

    Delay(1)

    adbClick_wbb(187, 345)

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(session.get("setSpeed") = 3)
            continueTime := 1
        else
            continueTime := 3

        if (TryWonderPickDexSwipeRegister()) {
            failSafeTime := 0
        } else if(FindOrLoseImage("Pack_SkipButtonAfterOpenPack", 0, failSafeTime)) {
            adbClick_wbb(239, 497)
        } else if(FindOrLoseImage("Create_WelcomePopup", 0, failSafeTime)) { ;click through to end of tut screen
            break
        } else if(FindOrLoseImage("Pack_NextButtonAfterOpenPack", 0, failSafeTime)) {
            adbClick_wbb(146, 494) ;146, 494
        } else if(FindOrLoseImage("Next2", 0, failSafeTime)) {
            adbClick_wbb(146, 494) ;146, 494
        } else {
            adbClick_wbb(187, 345)
            Delay(1)
            adbClick_wbb(143, 492)
            Delay(1)
            adbClick_wbb(143, 492)
            Delay(1)
        }
        Delay(1)

        ; adbClick_wbb(66, 446)
        ; Delay(1)
        ; adbClick_wbb(66, 446)
        ; Delay(1)
        ; adbClick_wbb(66, 446)
        ; Delay(1)
        ; adbClick_wbb(187, 345)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for End`n(" . failSafeTime . "/45 seconds)")
    }

    FindImageAndClick("Create_FullFreepackInMainCenter", 192, 449) ;click until at main menu
    EnterGameFromWelcomeIfNeeded() ; 1.7.0 forces restart after WP onto Welcome before GoToMain

    return true
}

DismissMainCloseAlertWindow(context := "") {
    if(!FindOrLoseImage("Common_CloseAlertWindowInMain", 0, , , true))
        return false

    LogInfo("Dismissed close-alert popup | context=" . context)
    if(context != "")
        CreateStatusMessage("Closing app quit confirmation`n" . context,,,, false)
    else
        CreateStatusMessage("Closing app quit confirmation",,,, false)

    adbClick_wbb(75, 365)
    Delay(1)
    return true
}

; After create-tutorial WP, 1.7.0 always forces an app restart onto Welcome (Tap to Start).
; ESC there opens quit confirmation — tap to enter instead.
; Returns true once past title screen (home/shop/news X/etc.).
EnterGameFromWelcomeIfNeeded(timeoutSec := 60) {
    global session

    session.set("failSafe", A_TickCount)
    Loop {
        ; Already in-game (including News/X overlays) — let GoToMain use ESC.
        if (FindOrLoseImage("Common_ShopButtonInMain", 0, 0, , true)
            || FindOrLoseImage("Common_ActivatedHomeInMainMenu", 0, 0, , true)
            || FindOrLoseImage("Pack_PackPointButton", 0, 0, , true)
            || FindOrLoseImage("Create_FullFreepackInMainCenter", 0, 0, , true)
            || FindOrLoseImage("WonderPick_WonderPickButtonInHome", 0, 0, , true)
            || FindOrLoseImage("Common_PopupXButtonInMain", 0, 0, , true))
            return true

        if (DismissMainCloseAlertWindow("Welcome gate")) {
            Delay(1)
            adbClick_wbb(140, 450) ; Tap to Start under quit dialog
            Delay(2)
            CreateStatusMessage("Entering game from Welcome...")
            continue
        }

        if (FindOrLoseImage("Create_WelcomePopup", 0, 0, , true)
            || FindOrLoseImage("Boot_Welcome", 0, 0, , true)
            || FindOrLoseImage("Boot_Welcome2", 0, 0, , true)) {
            adbClick_wbb(140, 450) ; Tap to Start
            Delay(2)
            CreateStatusMessage("Entering game from Welcome...")
            continue
        }

        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting past Welcome`n(" . failSafeTime . "/" . timeoutSec . " seconds)")
        if (failSafeTime >= timeoutSec)
            return false
    }
}

TryDismisMyCardsTutorial(failSafeTime) {
    if (!FindOrLoseImage("Common_BlurryMyCards", 0, , , true)) {
        return false
    }

    adbClick(168, 433)
    Delay(1)
    adbClick(168, 433)
    Delay(1)
    adbClick(168, 433)
    Delay(10)

    adbClick(168, 471)
    Delay(1)
    adbClick(168, 471)
    Delay(1)
    adbClick(168, 471)
    Delay(1)
    adbClick(168, 471)
    Delay(10)

    adbClick(168, 432)
    Delay(10)
}
