; Mission navigation and reward claiming

HomeAndMission(homeonly := 0, completeSecondMisson=false) {
    global session

    Sleep, 250
    Leveled := 0
    Loop {
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop {
            FindImageAndClick("Mission_ThemeCollectionButtonIcon", 261, 478, , 1000, 1)
            Delay(1)

            if(FindOrLoseImage("Mission_ThemeCollectionButtonIcon", 0, failSafeTime)){
                break
            }
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        }
        if(!homeonly){
            FindImageAndClick("Mission_ThemeCollectionButtonIcon", 261, 478, , 1000)

            wonderpicked := 0
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            Loop {
                Delay(1)

                Loop {
                    if (completeSecondMisson){
                        adbClick_wbb(150, 390)
                    }
                    else {
                        adbClick_wbb(150, 286)
                    }
                    Delay(1)

                    if(FindOrLoseImage("Mission_ThemeCollectionButtonIcon", 1, , 10)){
                        break
                    }
                }

                if(FindOrLoseImage("Mission_MissionIconTopAreaInDetails", 0, failSafeTime) || FindOrLoseImage("Mission_MissionIconTopAreaInDetailsAlt", 0, failSafeTime))
                    break

                if(FindOrLoseImage("Create_SoloBattleMissionIconInDetail", 0, failSafeTime)) {
                    SetBeginnerMissionsDone()
                    return
                }

                if (FindOrLoseImage("Mission_FirstWonderpickMissionIconInDetails", 0, failSafeTime)){
                    adbClick_wbb(141, 396) ; click try it and go to wonderpick page
                    DoWonderPickOnly()
                    wonderpicked := 1
                    break
                }

                failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            }
            if(!wonderpicked)
                break
        } else
            break
    }

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        Delay(1)

        adbClick_wbb(139, 424) ;clicks complete mission
        Delay(1)
        clickButton := FindOrLoseImage("Common_ColorChangeButton", 0, failSafeTime, 80)
        if(clickButton) {
            adbClick_wbb(110, 435)
            Delay(1)
        }
        else if(FindOrLoseImage("Common_ShopButtonInMain", 1, failSafeTime)) {
            GoToMain()
            break
        }
        else
            break
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("In failsafe for WonderPick. " . failSafeTime "/45 seconds")
    }
    return Leveled
}

;-------------------------------------------------------------------------------
; ClaimAllMissionRewards - Unified single-pass claim for Daily + Special missions.
; Handles the full Special-event lifecycle: AdvanceSpecialEventSteps, Elite Deck
; claims and per-event metadata (claimCount). X remains legacy status metadata
; and does not decide whether an active event can be claimed.
; Returns {daily: bool, special: bool, eliteDeckRestart: bool}.
;-------------------------------------------------------------------------------
ClaimAllMissionRewards(claimDaily := false, claimSpecial := false, accountMeta := "") {
    global botConfig, session

    if (!claimDaily && !claimSpecial)
        return {daily: false, special: false, eliteDeckRestart: false}

    method := botConfig.get("deleteMethod")

    ; --- Special-mission eligibility & advance ---
    specialEligible := false
    if (claimSpecial) {
        if (botConfig.get("claimSpecialMissions") = 1
            && !session.get("missionDoneList")["specialMissionsDone"]
            && (method = "Inject 13P+" || method = "Inject Wonderpick 96P+" || method = "Inject Rewards")) {

            if (!IsObject(accountMeta) && session.get("injectMethod") && session.get("loadedAccount") && session.get("accountFileName") != "") {
                accountMetaPath := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName") . "\" . session.get("accountFileName")
                accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), accountMetaPath)
            }

            syncSpecialEvents()

            if (!IsObject(accountMeta) || AccountEligibility_NeedsSpecialMissionClaim(accountMeta))
                specialEligible := true
        }
    }

    session.set("forceReceiveGiftThisRun", 0)
    session.set("specialMissionClaimUiEvents", {})

    advance := {"advancedAny": false, "needClaimUi": false, "forceGift": false, "eliteDeckClaim": false, "claimUiEvents": {}}
    if (specialEligible) {
        accountMetaPath := ""
        if (session.get("injectMethod") && session.get("loadedAccount") && session.get("accountFileName") != "")
            accountMetaPath := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName") . "\" . session.get("accountFileName")

        if (accountMetaPath != "")
            advance := AccountMetadata_AdvanceSpecialEventSteps(session.get("scriptName"), session.get("accountFileName"), accountMetaPath)

        if (advance["forceGift"])
            session.set("forceReceiveGiftThisRun", 1)
        if (IsObject(advance["claimUiEvents"]))
            session.set("specialMissionClaimUiEvents", advance["claimUiEvents"])
    }

    doSpecial := specialEligible && advance["needClaimUi"]
    eliteDeckClaim := advance["eliteDeckClaim"]

    ; --- Navigate to Missions page (single navigation for both Daily + Special) ---
    if (!NavigateToMissions())
        return {daily: false, special: false, eliteDeckRestart: false}

    ; --- Elite Deck setup ---
    if (doSpecial && eliteDeckClaim) {
        adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
        RunWait, % adbCommand . " shell rm -f /data/ptcgp/result.rc", , Hide
        RunWait, % adbCommand . " shell rm -f /data/ptcgp/result.log", , Hide
        if (isTerminatePTCGPHelperApp())
            InitPackOpening(true)
    }

    ; --- Check if all Special events are expired ---
    isAllEventExpired := true
    if (doSpecial) {
        for specialEventName, specialEventObj in session.get("specialEventList") {
            if(!specialEventObj.isExpiredSpecialEvent()){
                isAllEventExpired := false
                break
            }
        }
    }

    ; --- Single-pass scan loop ---
    eventResult := initEventResult()
    dailyClaimed := false
    specialDone := !doSpecial || isAllEventExpired
    eliteDeckRestart := false

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    movedRightCount := 0
    maxMissionPages := 15
    Loop {
        if ((!claimDaily || dailyClaimed) && specialDone)
            break

        Delay(2)

        ; special case: welcome back screen
        if (FindOrLoseImage("Mission_WelcomeBackPreClaim", 0, 0, , true)) {
            LogInfo(logContext . ": dismissing WelcomeBackPreClaim", "ADB.txt")
            CreateStatusMessage("Welcome Back missions`nDismissing PreClaim...",,,, false)
            adbClick_wbb(137, 389)
            Delay(1)
        }

        ; Check for Daily Missions on this page
        if (claimDaily && !dailyClaimed && FindOrLoseImage("Mission_DailyMissionImage", 0, failSafeTime)) {
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            Loop {
                Delay(2)
                adbClick(174, 427)
                adbClick(174, 427)
                Delay(1)
                if(FindOrLoseImage("Mission_CompleteGotAllClaims", 0, 0)) {
                    dailyClaimed := true
                    break
                }
                failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
                if (failSafeTime > 20)
                    break
            }
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            continue
        }

        ; Check for Special Missions on this page
        if (doSpecial && !specialDone) {
            ; Elite Deck: park and retry if on Elite Deck page
            if (eliteDeckClaim && !isAllEventGotReward(eventResult)) {
                eliteDeckVisible := false
                for specialEventName, specialEventObj in session.get("specialEventList") {
                    if (specialEventObj.isEliteDeck && !specialEventObj.isExpiredSpecialEvent()) {
                        if (specialEventObj.isExistNeedleInScreen(session.get("winTitle")) = 2) {
                            eliteDeckVisible := true
                            break
                        }
                    }
                }
                if (eliteDeckVisible) {
                    session.set("failSafe", A_TickCount)
                    parkTime := 0
                    parked := false
                    Loop {
                        claimedEventName := ClaimVisibleEventRewards(eventResult)
                        if (claimedEventName) {
                            parked := true
                            if (session.get("injectMethod") && session.get("loadedAccount") && session.get("accountFileName") != "") {
                                accountMetaPath := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName") . "\" . session.get("accountFileName")
                                AccountMetadata_BumpSpecialEventClaim(session.get("scriptName"), session.get("accountFileName"), claimedEventName, accountMetaPath)
                            }
                            if (HelperHasCardResult()) {
                                eliteDeckRestart := true
                                specialDone := true
                            }
                            ; already claimed
                            if (FindOrLoseImage("Mission_CompleteGotAllClaims", 0, failSafeTime, , true)) {
                                specialDone := true
                            }
                            break
                        }
                        Delay(1)
                        parkTime := (A_TickCount - session.get("failSafe")) // 1000
                        CreateStatusMessage("Parking on Elite Deck claim page...`n(" . parkTime . "/45 seconds)")
                        if (parkTime > 45)
                            break
                    }
                    if (parked) {
                        session.set("failSafe", A_TickCount)
                        failSafeTime := 0
                        if (eliteDeckRestart)
                            break
                        if (isAllEventGotReward(eventResult))
                            specialDone := true
                        continue
                    }
                }
            }

            claimedEventName := ClaimVisibleEventRewards(eventResult)
            if (claimedEventName) {
                session.set("failSafe", A_TickCount)
                failSafeTime := 0
                if (session.get("injectMethod") && session.get("loadedAccount") && session.get("accountFileName") != "") {
                    accountMetaPath := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName") . "\" . session.get("accountFileName")
                    AccountMetadata_BumpSpecialEventClaim(session.get("scriptName"), session.get("accountFileName"), claimedEventName, accountMetaPath)
                }
                if (isAllEventGotReward(eventResult))
                    specialDone := true
                continue
            }
        }

        ; Wrapped around (Premium Lock = full loop completed)
        if(FindOrLoseImage("Mission_PremiumLockImage", 0, failSafeTime))
            break

        movedRightCount++
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Scanning mission rewards page " . movedRightCount . "`n(" . failSafeTime . "/60 seconds)")
        adbClick_wbb(197, 459)
        Delay(0.2)
        adbClick_wbb(175, 445)
        Delay(3)

        if (failSafeTime > 60 || movedRightCount >= maxMissionPages)
            break
    }

    ; --- Elite Deck restart: finish claim then re-run for remaining rewards ---
    if (eliteDeckRestart && eliteDeckClaim && HelperHasCardResult()) {
        eliteDeckResult := ReadEliteDeckResult(45)
        FinishEliteDeckClaim(eliteDeckResult)
        return ClaimAllMissionRewards(false, claimSpecial, accountMeta)
    }

    ; --- Post-claim metadata for Special missions ---
    if (specialEligible) {
        session.get("missionDoneList")["specialMissionsDone"] := 1
        session.set("cantOpenMorePacks", 0)

        if (advance["advancedAny"] && session.get("injectMethod") && session.get("loadedAccount") && session.get("accountFileName") != "") {
            accountMetaPath := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName") . "\" . session.get("accountFileName")
            accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), accountMetaPath)
            AccountMetadata_ApplySpecialMissionXFlag(session.get("scriptName"), session.get("accountFileName"), accountMeta)
            setMetaData()
        }
    }

    return {daily: dailyClaimed, special: specialEligible, eliteDeckRestart: false}
}

;-------------------------------------------------------------------------------
; NavigateToMissions - Navigate from Main to the Missions page and activate the List tab.
; Returns true if the missions page was reached, false on timeout.
;-------------------------------------------------------------------------------
NavigateToMissions() {
    global session

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbClick(261, 478)
        Delay(1)
        if (FindOrLoseImage("Mission_ActivatedBeginnerMissionTabButton", 0, failSafeTime)
            || FindOrLoseImage("Mission_ActivatedListTabButton", 0, failSafeTime)
            || FindOrLoseImage("Mission_GoToDexButtonIcon", 0, failSafeTime)
            || FindOrLoseImage("Mission_DailyMissionImage", 0, failSafeTime))
            break
        if (FindOrLoseImage("MissionDeck", 0, failSafeTime)) {
            HandleMissionDeckFailsafe()
            return false
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        if (failSafeTime > 60) {
            restartGameInstance("Stuck navigating to Missions")
            return false
        }
        CreateStatusMessage("Moving to Missions...(" . failSafeTime . "/60 seconds)")
    }

    ; Activate the List tab and confirm ListActivated is visible for 2 seconds
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if (FindOrLoseImage("Mission_ActivatedListTabButton", 0, 0)) {
            confirmedStart := A_TickCount
            Loop {
                if (!FindOrLoseImage("Mission_ActivatedListTabButton", 0, 0)) {
                    confirmedStart := 0
                    break
                }
                if (A_TickCount - confirmedStart >= 2000)
                    return true
                Delay(0.5)
            }
        }
        Delay(1)
        adbClick_wbb(31, 495)
        Delay(2)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        if (failSafeTime > 20) {
            LogWarn("NavigateToMissions: timed out waiting for ListActivated")
            return false
        }
        CreateStatusMessage("Activating List tab...(" . failSafeTime . "/20 seconds)")
    }

    return true
}

; After claiming an Elite Deck event or opening Gift packs: register the cards
; with the Helper (no Discord notification), then restart the game so their
; in-game registration is instant, and go back to Main so the run resumes.
; helperResult may already contain the parsed Helper result; if not, we try to
; recover it with a pre/post restart diff.
FinishEliteDeckClaim(helperResult := false, contextName := "Elite Deck", failedPrefix := "elitedeck") {
    global session

    CreateStatusMessage("Registering " . contextName . " cards...",,,, false)

    ; Restart the game first: the cards are only reliably written to
    ; MissionUserPrefs after the app boots back up and syncs with the server.
    ; The pre-claim snapshot was already saved by InitPackOpening(true).
    TerminateHelper()
    CreateStatusMessage("Restarting game to speed up " . contextName . " registration...",,,, false)
    closePTCGPApp()
    Sleep, 100
    startPTCGPApp()

    ; Treat the restart as a boot gate: reuse the same sequence used when
    ; loading an injected account (SpeedMod menu), then run the normal
    ; startPreProcess so the game reaches the expected main screen.
    waitForAppBootScreen()
    SetConfiguredGameSpeed()
    Delay(1)
    adbClick_wbb(51, 297)
    Delay(1)
    ; Elite Deck restart must always land at Home, regardless of bot mode.
    startPreProcess("Inject Rewards")

    ; After the restart, give the game time to sync the cards into
    ; MissionUserPrefs before capturing the post-restart snapshot.
    Sleep, 3000

    ; Use the Helper result captured during the claim if it is already parseable.
    ; Otherwise fall back to a pre/post restart diff of MissionUserPrefs.
    result := helperResult
    if (!result) {
        SavePackOpeningMissionUserPrefsSnapshot("post")
        result := RecoverPack()
    }
    if (result) {
        LogToCardDatabase(result)
        AddShinedustToDatabase(result.shinedust)
        LogInfo("Instance: " . session.get("scriptName") . " | " . contextName . " cards stored to card database")
    } else {
        ; Save diagnostics (no Discord spam) so we can inspect why the diff failed.
        failedDir := getScriptBaseFolder() . "\Logs\failed"
        uniquePrefix := A_Now . "_" . session.get("scriptName") . "_" . failedPrefix
        PullPackOpeningMissionUserPrefsSnapshot("pre", failedDir, uniquePrefix)
        PullPackOpeningMissionUserPrefsSnapshot("post", failedDir, uniquePrefix)
        PullPackOpeningResultLog(failedDir, uniquePrefix)
        LogWarn("Instance: " . session.get("scriptName") . " | " . contextName . " card recognition failed; diagnostics saved to Logs\failed with prefix " . uniquePrefix)
    }
    GoToMain()
}

ClaimVisibleEventRewards(eventResult) {
    global session

    claimUiEvents := session.get("specialMissionClaimUiEvents")
    hasClaimFilter := IsObject(claimUiEvents)
    if (hasClaimFilter) {
        filterCount := 0
        for k, v in claimUiEvents
            filterCount++
        if (filterCount < 1)
            hasClaimFilter := false
    }

    for specialEventName, specialEventObj in session.get("specialEventList") {
        if(eventResult.HasKey(specialEventName) && eventResult[specialEventName])
            continue
        if(specialEventObj.isExpiredSpecialEvent()){
            eventResult[specialEventName] := true
            continue
        }
        ; Only attempt claim UI for events advanced onto a ClaimDay this run.
        if (hasClaimFilter && !claimUiEvents.HasKey(specialEventName)) {
            eventResult[specialEventName] := true
            continue
        }

        if (specialEventObj.isExistNeedleInScreen(session.get("winTitle")) = 2){
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            Loop{
                adbClick_wbb(175, 422)
                Delay(1)
                adbClick_wbb(138, 451)
                Delay(1)

                ; Elite Deck events: do not wait for the usual claim-complete needle.
                ; The Helper is already watching MissionUserPrefs; as soon as it writes
                ; result.rc the claim has been processed and we can proceed to the
                ; restart + card registration in FinishEliteDeckClaim.
                if (specialEventObj.isEliteDeck) {
                    if (HelperHasCardResult()) {
                        eventResult[specialEventName] := true
                        return specialEventName
                    }
                }
                if (FindOrLoseImage("Mission_CompleteGotAllClaims", 0, failSafeTime, , true)) {
                    eventResult[specialEventName] := true
                    return specialEventName
                }

                failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
                CreateStatusMessage("Get reward event: " . specialEventName . "`n(" . failSafeTime . "/45 seconds)")
                if (failSafeTime > 45) {
                    ; For Elite Deck, do not mark the event as claimed until the
                    ; Helper actually reports a card result. Returning false lets
                    ; GetEventRewards keep retrying or scrolling instead of giving up.
                    if (!specialEventObj.isEliteDeck)
                        eventResult[specialEventName] := true
                    return false
                }
            }
        }
    }

    return false
}

; Failsafe if Missions page lands on 'Deck' mission tutorial.
HandleMissionDeckFailsafe() {
    Sleep, 500
    adbInput("111") ; ESC
    Sleep, 500
    adbInput("111") ; ESC
    Sleep, 500
    adbInput("111") ; ESC
    Sleep, 500
    adbInput("111") ; ESC
    Sleep, 500
    adbClick(146,438)
    Sleep, 1500
    adbInput("111") ; ESC to home screen
    Sleep, 1000
    return true
}
