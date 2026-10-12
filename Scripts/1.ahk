#SingleInstance, Force
SetMouseDelay, -1
SetDefaultMouseSpeed, 0
SetBatchLines, -1
SetTitleMatchMode, 3
CoordMode, Pixel, Screen
#NoEnv

#Include %A_ScriptDir%\Include\
#Include BotCommon.ahk
pToken := Gdip_Startup()
;#Include %A_ScriptDir%\Include\Recorder.ahk
#Include Packs.ahk
#Include RarityBorder.ahk
#Include SpecialEvent.ahk
#Include HourglassSpend.ahk
#Include BotAccountMeta.ahk
#Include BotAccountRename.ahk
#Include BotToggles.ahk
#Include BotStopSignals.ahk
#Include BotPackEvaluation.ahk
#Include BotPackOpening.ahk
#Include BotMissions.ahk
#Include BotWonderPick.ahk
#Include BotTutorial.ahk
#Include BotAccountMenu.ahk
#Include BotDebugTools.ahk

InitializeHiddenConsole()

; Register OnExit handler to clean up ADB shell properly when script exits
; DISABLED - was causing Reload delays due to blocking ADB shell communication
; OnExit("CleanupOnExit")

; Register message handler to receive "stop after run" signal from instance 1
; WM_USER (0x400) + 0x100 = custom message for stop after run
OnMessage(0x500, "OnStopAfterRunMessage")
OnMessage(0x007E, "OnMonitorWake")
OnExit("CleanupBeforeExit")

global session := new Session()
global botConfig := new BotConfig()
botConfig.loadSettingsToConfig("ALL")
LogSettingsSnapshotForRun(botConfig.settingsFile)

parsePackData()
pokemonList := getKeyList(session.get("pokemonPackObj"))
generatePackCoordinates()

parseDictionaryData("en")
parseDictionaryData("de")
parseDictionaryData("jp")
parseDictionaryData("cn")

session.set("s4tPendingTradeables", [])
session.set("s4tFoundTradeable", false)
session.set("deviceAccountXmlMap", {})
session.set("scriptName", StrReplace(A_ScriptName, ".ahk"))
AccountMetadata_CloseTempForInstance(session.get("scriptName"))
session.set("winTitle", StrReplace(A_ScriptName, ".ahk"))
session.set("scriptIniFile", A_ScriptDir . "\" . session.get("scriptName") . ".ini")
session.set("stopToggle", false)
session.set("friended", false)
session.set("injectMethod", false)
session.set("dateChange", false)
session.set("foundGP", false)
session.set("isReloadAfterAddFriends", false)
session.set("avgtotalSeconds", false)
session.set("hhours", 0)
session.set("mminutes", 0)
session.set("sseconds", 0)
session.set("aminutes", 0)
session.set("aseconds", 0)
session.set("packsInPool", 0)
session.set("packsThisRun", 0)
session.set("cantOpenMorePacks", 0)
session.set("isSkipSelectExpansion", 0)
session.set("creationDate", "")

session.set("specialEventList", {})

session.set("rerolls_local", 0)
session.set("rerollStartTime_local", A_TickCount)

session.set("maxAccountPackNum", 9999)
session.set("missionDoneList", {"beginnerMissionsDone": 0, "specialMissionsDone": 0, "resetSpecialMissionsDone": 0, "accountHasPackInTesting": 0, "receivedGiftDone": 0})
session.set("forceReceiveGiftThisRun", 0)
session.set("specialMissionClaimUiEvents", {})
activatedPackList := []
For idx, value in botConfig.packSettings {
    if(value == 1){
        activatedPackList.Push(idx)
    }
}
session.set("packList", activatedPackList)

session.set("dbg_bbox", 0)
session.set("dbg_bboxNpause", 0)

session.set("failSafe", A_TickCount) ; Initialize failSafe timer at script startup

; Survives SafeReload/Reload so "stop at end of run" still applies after restartGameInstance (e.g. failsafe + DeadCheck unfriend path)
IniRead, stopAfterRunPending, % session.get("scriptIniFile"), UserSettings, stopAfterRunPending, 0
if (stopAfterRunPending = 1) {
    session.set("stopToggle", true)
    IniWrite, 0, % session.get("scriptIniFile"), UserSettings, stopAfterRunPending
}

originalDeleteMethod := botConfig.get("deleteMethod")
if (MigrateDeleteMethod(originalDeleteMethod) != originalDeleteMethod) {
    validMethods := "Create Bots (13P)|Inject 13P+|Inject Wonderpick 96P+|Inject Rewards|Rename Account"
    if (!InStr(validMethods, originalDeleteMethod)) {
        botConfig.set("deleteMethod", "Create Bots (13P)", "General")
        botConfig.saveConfigToSettings("General")
    }
}

session.set("packMethod", botConfig.get("packMethod"))
if(botConfig.get("deleteMethod") != "Inject Wonderpick 96P+")
    session.set("packMethod", 0)
session.set("packMethodSkipFriendRenew", 0)
session.set("packMethodStayOnPackScreen", 0)

IniRead, DeadCheck, % session.get("scriptIniFile"), UserSettings, DeadCheck, 0
IniRead, friendCleanupPending, % session.get("scriptIniFile"), UserSettings, friendCleanupPending, 0
friendCleanupRestored := false
if (friendCleanupPending = 1) {
    IniRead, friendCleanupReason, % session.get("scriptIniFile"), Recovery, friendCleanupReason,
    friendCleanupRestored := RestoreLoadedAccountForRecovery()
    if (session.get("loadedAccount")) {
        DeadCheck := 1
        IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
        session.set("friended", true)
        LogInfo("Friend cleanup pending found at startup. Entering cleanup recovery. Reason: " . friendCleanupReason, "GroupReroll.txt")
    } else {
        DeadCheck := 0
        IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck
        ClearFriendCleanupPending()
        LogInfo("Friend cleanup pending ignored at startup because no recovery account was saved. Reason: " . friendCleanupReason, "GroupReroll.txt")
    }
}
if (DeadCheck = 1 && !friendCleanupRestored)
    RestoreLoadedAccountForRecovery()

IniRead, rerollsValue, % session.get("scriptIniFile"), Metrics, rerolls, 0
IniRead, rerollStartTimeValue, % session.get("scriptIniFile"), Metrics, rerollStartTime, -1

if(rerollStartTimeValue = -1)
    rerollStartTimeValue := A_TickCount

session.set("changeDate", getChangeDateTime()) ; get server reset time
session.set("rerolls", rerollsValue)
session.set("rerollStartTime", rerollStartTimeValue)
(botConfig.get("s4tEnabled")) ? session.set("maxAccountPackNum", 9999)

if(botConfig.get("heartBeat"))
    IniWrite, 1, %A_ScriptDir%\..\HeartBeat.ini, HeartBeat, % "Instance" . session.get("scriptName")

SetTimer, RefreshAccountLists, 3600000  ; Refresh Account list every hour

windowCoverHwnd := GetMuMuCoverWindowForMaintenance(session.get("winTitle"))
DirectlyPositionWindow()
Sleep, 500
setADBBaseInfo()
ConnectAdb()

Sleep, 500
CreateStatusMessage("Disabling background services...")
DisableBackgroundServices()

resetWindows()
RestoreMuMuCoverWindow(windowCoverHwnd, session.get("winTitle"))
MaxRetries := 10
RetryCount := 0
Loop {
    try {
        WinGetPos, x, y, Width, Height, % "ahk_id " . getMuMuHwnd(session.get("winTitle"))
        sleep, 1000
        OwnerWND := getMuMuHwnd(session.get("winTitle"))
        x4 := x + 4
        y4 := y + 529
        buttonWidth := 50

        Gui, New, +Owner%OwnerWND% -AlwaysOnTop +ToolWindow -Caption +LastFound -DPIScale
        Gui, Default
        Gui, Margin, 4, 4  ; Set margin for the GUI
        Gui, Font, s5 cGray Norm Bold, Segoe UI  ; Normal font for input labels
        Gui, Add, Button, % "x" . (buttonWidth * 0) . " y0 w" . buttonWidth . " h25 gReloadScript", Reload  (Shift+F5)
        Gui, Add, Button, % "x" . (buttonWidth * 1) . " y0 w" . buttonWidth . " h25 gPauseScript", Pause (Shift+F6)
        Gui, Add, Button, % "x" . (buttonWidth * 2) . " y0 w" . buttonWidth . " h25 gResumeScript", Resume (Shift+F6)
        Gui, Add, Button, % "x" . (buttonWidth * 3) . " y0 w" . buttonWidth . " h25 gStopScript", Stop (Shift+F7)
        Gui, Add, Button, % "x" . (buttonWidth * 4) . " y0 w" . buttonWidth . " h25 gDevMode", Dev Mode (Shift+F8)
        DllCall("SetWindowPos", "Ptr", WinExist(), "Ptr", 1  ; HWND_BOTTOM
            , "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)  ; SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE
        Gui, Show, NoActivate x%x4% y%y4%  w275 h30
        RestoreMuMuCoverWindow(windowCoverHwnd, session.get("winTitle"))
        break
    }
    catch {
        RetryCount++
        if (RetryCount >= MaxRetries) {
            CreateStatusMessage("Failed to create button GUI.",,,, false)
            break
        }
        Sleep, 1000
    }
    Delay(1)
    CreateStatusMessage("Trying to create button GUI...")
}

session.set("setSpeed", 3) ;always 1x/3x

if(InStr(botConfig.get("deleteMethod"), "Inject") || botConfig.get("deleteMethod") = "Rename Account")
    session.set("injectMethod", true)

initializeAdbShell()
RemoveOldFiles()
adbGrantOverlayPermission()

if(session.get("injectMethod"))
    createAccountList(session.get("scriptName"))

SetTimer, LiveMetricsTimer, 5000

if(session.get("injectMethod") && DeadCheck != 1) {
    ; loadAccount is called inside the loop after openPack is rolled
} else if(session.get("injectMethod") && DeadCheck = 1) {
    ; DeadCheck = 1: Start the Pokemon app for the stuck account (don't inject new account)
    AccountMetadata_CloseTempForInstance(session.get("scriptName"))
    startPTCGPApp()
}

if(isSevtFileExist())
    loadAllSevtFiles()

if(!session.get("injectMethod"))
    restartGameInstance("Initializing bot...", false)

; Define default swipe params.
adbSwipeX1 := Round(35 / 283 * 540)
adbSwipeX2 := Round(273 / 283 * 540)
adbSwipeY := Round((327 - 40) / 488 * 960)
global adbSwipeParams := adbSwipeX1 . " " . adbSwipeY . " " . adbSwipeX2 . " " . adbSwipeY . " " . botConfig.get("swipeSpeed")

if(DeadCheck = 1 && botConfig.get("deleteMethod") != "Create Bots (13P)") {
    CreateStatusMessage("Account is stuck! Restarting and unfriending...")
    session.set("friended", true)
    CreateStatusMessage("Stuck account still has friends. Unfriending accounts...")
    waitForAppBootScreen()
    SetConfiguredGameSpeed()
    adbClick_wbb(51, 297)
    Delay(1)
    startPreProcess(botConfig.get("deleteMethod"))
    if (session.get("injectMethod") && session.get("loadedAccount") && session.get("deviceAccount") != "") {
        AccountMetadata_SetLastLoggedInNow(session.get("deviceAccount"), session.get("scriptName"), session.get("accountFileName"))
        SetSpendHourglassMetadataFlag()
        GetHistoryOfAccount()
        EnsureAccountLanguageMetadata()
        GetAccountCreationDate()
        new_packcount := EvaluatePackCount()
        if (new_packcount != 0) {
            accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), session.get("loadedAccount"))
            accountMeta["deviceAccount"] := GetCurrentDeviceAccountForMetadata()
            accountMeta["packCount"] := new_packcount
            session.set("accountOpenPacks", new_packcount)
            AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)
        }
    }
    RemoveFriends()
    if(session.get("injectMethod") && session.get("loadedAccount")) {
        LogToFile("Recovery cleanup complete. Keeping recovered account in queue unless its XML was already updated: " . session.get("accountFileName"))
        ClearLoadedAccountRecovery()
        session.set("loadedAccount", false)
        session.set("currentLoadedAccountIndex", 0)
    }
    DeadCheck := 0
    IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck
    createAccountList(session.get("scriptName"))
    CleanupBeforeExit()
    SafeReload()
} else if(DeadCheck = 1 && botConfig.get("deleteMethod") = "Create Bots (13P)") {
    CreateStatusMessage("New account creation is stuck! Deleting account...")
    Delay(5)
    menuDeleteStart()
    CleanupBeforeExit()
    SafeReload()
} else {
    ; in injection mode, we dont need to reload

    Loop {
        clearMissionCache()
        session.set("isReloadAfterAddFriends", false)
        session.set("favEnteredFromHome", false)
        Randmax := session.get("packList").Length()
        Random, rand, 1, Randmax
        session.set("openPack", session.get("packList")[rand])
        session.set("friended", false)
        IniWrite, 1, %A_ScriptDir%\..\HeartBeat.ini, HeartBeat, % "Instance" . session.get("scriptName")

        session.set("changeDate", getChangeDateTime()) ; get server reset time

        if (session.get("avgtotalSeconds") > 0 ) {
            StartTime := session.get("changeDate")
            StartTime += -(1.5*session.get("avgtotalSeconds")), Seconds
            EndTime := session.get("changeDate")
            EndTime += (0.5*session.get("avgtotalSeconds")), Seconds
        } else {
            StartTime := session.get("changeDate")
            StartTime += -5, minutes
            EndTime := session.get("changeDate")
            EndTime += 2, minutes
        }

        if(botConfig.get("deleteMethod") = "Create Bots (13P)"){
            StartTime := session.get("changeDate")
            StartTime += -900, Seconds
            EndTime := session.get("changeDate")
            EndTime += 120, Seconds
        }

        StartCurrentTimeDiff := A_Now
        EnvSub, StartCurrentTimeDiff, %StartTime%, Seconds
        EndCurrentTimeDiff := A_Now
        EnvSub, EndCurrentTimeDiff, %EndTime%, Seconds

        session.set("dateChange", false)

        while (StartCurrentTimeDiff > 0 && EndCurrentTimeDiff < 0) {
            FormatTime, formattedEndTime, %EndTime%, HH:mm:ss
            CreateStatusMessage("Waiting for daily server reset until " . formattedEndTime ,,,, false)
            session.set("dateChange", true)
            writeLastActivityEpoch(session.get("scriptName"), 4000)
            Sleep, 5000

            StartCurrentTimeDiff := A_Now
            EnvSub, StartCurrentTimeDiff, %StartTime%, Seconds
            EndCurrentTimeDiff := A_Now
            EnvSub, EndCurrentTimeDiff, %EndTime%, Seconds
        }

        session.set("VRAMUsage", GetVRAMByScriptName(session.get("scriptName")))
        if(session.get("VRAMUsage").Usage > 1){
            LogInfo("[" . A_ScriptName . "] GPU usage exceeds the threshold and restarts. VRAM Usage(" . session.get("VRAMUsage").Mode . "): " . session.get("VRAMUsage").Usage . " GB", "Restart.txt")
            CreateStatusMessage("Restarting Instance...",,,, false)
            restartInstance()
            RefreshAdbConnectionAfterInstanceRestart(45000)
            DirectlyPositionWindow()
            RestoreMuMuCoverWindow(GetMuMuCoverWindowForMaintenance(session.get("winTitle")), session.get("winTitle"))
            CreateStatusMessage("Restart complete!",,,, false)
            LogInfo("[" . A_ScriptName . "] Restart complete!", "Restart.txt")
            session.set("loadedAccount", false)
        }

        resetShowcaseLikesIfNewCycle()

        ; Only refresh account lists if we're not in injection mode or if no account is loaded
        ; This prevents constant list regeneration during injection
        if(session.get("injectMethod") && !session.get("loadedAccount")) {
            createAccountList(session.get("scriptName"))
        }

        ; For injection methods, load account only if we don't already have one
        if(session.get("injectMethod")) {
            ; Only load account if we don't already have one loaded
            if(!session.get("loadedAccount")) {
                session.set("loadedAccount", loadAccount(session.get("openPack")))
            }

            ; If no account could be loaded for injection methods, handle appropriately
            if(!session.get("loadedAccount")) {
                ; Check user setting for what to do when no eligible accounts
                if(botConfig.get("waitForEligibleAccounts") = 1) {
                    ; Wait for eligible accounts to become available
                    ; Simple approach - just show wait message and sleep
                    CreateStatusMessage("No eligible accounts available for " . botConfig.get("deleteMethod") . ".`nWaiting 1 minute before checking again...", "NoEligibleAccount", 0, 0, false)
                    LogInfo("No eligible accounts available for " . botConfig.get("deleteMethod") . ". Waiting 1 minute...")

                    ; Check stopToggle immediately, then wait 1 minute before checking again
                    if (session.get("stopToggle")){
                        CleanupBeforeExit()
                        ExitApp
                    }
                    Sleep, 60000  ; 1 minute
                    continue  ; Go back to start of loop to check again
                } else {
                    CleanupBeforeExit()
                    ExitApp
                }
            }

            ; If we reach here, we have a valid loaded account for injection
            LogInfo("Successfully loaded account for injection: " . session.get("accountFileName"))
            guiName := "NoEligibleAccount" . session.get("scriptName")
            Gui, %guiName%:+LastFoundExist
            if WinExist()
                Gui, %guiName%:Destroy
        }

        ; Download friend IDs for injection methods when group reroll is enabled
        if(session.get("injectMethod")) {
            if(botConfig.get("groupRerollEnabled")) {
                mainIdsURL := botConfig.get("mainIdsURL")
                if(mainIdsURL) {
                    DownloadFile(mainIdsURL, "ids.txt")
                }
            }
        }

        waitForAppBootScreen()
        SetConfiguredGameSpeed()
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)

        session.set("packsInPool", 0)
        session.set("packsThisRun", 0)
        session.set("cantOpenMorePacks", 0)
        session.set("keepAccount", false)
        session.set("s4tFoundTradeable", false)

        startPreProcess(botConfig.get("deleteMethod"))

        methodType := botConfig.get("deleteMethod")
        if ((methodType = "Inject 13P+" || methodType = "Inject Rewards") && IsFunc("EnsureAccountFriendInfo")) {
            session.set("accountFriendInfoReturnedHome", false)
            EnsureAccountFriendInfo(methodType)
            if (session.get("accountFriendInfoReturnedHome"))
                GoToMain()
        }
        if (session.get("injectMethod") && session.get("loadedAccount") && session.get("deviceAccount") != "") {
            AccountMetadata_SetLastLoggedInNow(session.get("deviceAccount"), session.get("scriptName"), session.get("accountFileName"))
            SetSpendHourglassMetadataFlag()
            GetHistoryOfAccount()
            EnsureAccountLanguageMetadata()
            GetAccountCreationDate()
            new_packcount := EvaluatePackCount()
            if (new_packcount != 0) {
                accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), session.get("loadedAccount"))
                accountMeta["deviceAccount"] := GetCurrentDeviceAccountForMetadata()
                accountMeta["packCount"] := new_packcount
                session.set("accountOpenPacks", new_packcount)
                AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)

                if(botConfig.get("deleteMethod") = "Inject Wonderpick 96P+" && new_packcount < botConfig.get("injectWonderpickMinPacks")) {
                    ; we now have a proper pack count and can evaluate if this is valid or if this is a waste of time
                    MarkAccountAsUsed()
                    session.set("loadedAccount", false)
                    restartGameInstance("New Run", false)
                    continue
                }
            }
        }
        if(!session.get("injectMethod") || !session.get("loadedAccount")) {
            DoTutorial()
            session.set("accountOpenPacks", 0) ;tutorial packs don't count
        }

        if(botConfig.get("deleteMethod") = "Inject Rewards")
            Goto, EndOfRun

        if(botConfig.get("deleteMethod") = "Rename Account") {
            if (!AccountRename_CanRenameCurrentAccount()) {
                CreateStatusMessage("Rename Account`nSkipped (age/rename cooldown)",,,, false)
                if (session.get("injectMethod") && session.get("loadedAccount")) {
                    MarkAccountAsClaimed()
                    LogDebug("Marked non-renameable account as claimed: " . session.get("accountFileName"))
                    session.set("loadedAccount", false)
                }
                continue
            }

            renamedUsername := DoRenameAccount()
            if (renamedUsername != "") {
                accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), session.get("loadedAccount"))
                accountMeta["deviceAccount"] := GetCurrentDeviceAccountForMetadata()
                accountMeta["accountName"] := renamedUsername
                accountMeta["lastRenamedAt"] := AccountMetadata_Now()
                AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)
                session.set("accountName", renamedUsername)
                session.set("accountLastRenamedAt", accountMeta["lastRenamedAt"])
                LogInfo("Renamed account to: " . renamedUsername)
            }
            if (session.get("injectMethod") && session.get("loadedAccount")) {
                MarkAccountAsClaimed()
                LogDebug("Marked renamed account as claimed (reusable): " . session.get("accountFileName"))
                session.set("loadedAccount", false)
            }
            continue
        }

        if(botConfig.get("deleteMethod") = "Create Bots (13P)"){
            EnterGameFromWelcomeIfNeeded() ; 1.7.0 forces restart onto Welcome; tap before GoToMain ESC
            GoToMain()
            wonderPicked := DoWonderPick()
        }

        session.set("friendsAdded", AddFriends())

        if(botConfig.get("deleteMethod") = "Inject Wonderpick 96P+"){
            if(session.get("friendsAdded") == false){
                Loop {
                    if(FindOrLoseImage("Friend_BottomDarkHomeIcon", 0))
                        break
                    else{
                        adbClick_wbb(40, 516)
                        Delay(0.1)
                        adbClick_wbb(175, 445)
                        DelayH(500)
                    }
                }
            }
            if(!session.get("isReloadAfterAddFriends")) {
                GoToMain()
                if (session.get("packFavoriteSet"))
                    EnterFavouritePackFromHome()
            }
            else if(session.get("packFavoriteSet")) {
                EnterFavouritePackFromHome()
            }
            else{
                clickX := getPackCoordXInHome()
                WaitForPackPointButtonFromHome(clickX, 203, "after friend reload")
            }

        }

        SelectPack("First")
        if(session.get("cantOpenMorePacks"))
            Goto, MidOfRun

        PackOpening()
        if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
            Goto, MidOfRun

        ; Pack method handling
        if(session.get("packMethod")) {
            session.set("friendsAdded", PackMethod_RenewFriends())
            if (!PackMethod_ConsumeStayOnPackScreen()) {
                GoToMain()
                SelectPack()
            }
            if(session.get("cantOpenMorePacks"))
                Goto, MidOfRun
        }
        if (isTerminatePTCGPHelperApp()) {
            InitPackOpening()
        }
        PackOpening()
        if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
            Goto, MidOfRun

        ; Hourglass opening for non-injection methods ONLY
        if(!session.get("injectMethod"))
            HourglassOpening() ;deletemethod check in here at the start

        ; Wonder pick additional handling - only for non-injection methods
        if(wonderPicked && !session.get("injectMethod")) {
            if(session.get("packMethod")) {
                session.set("friendsAdded", PackMethod_RenewFriends())
                SelectPack("HGPack")
                PackOpening()
            } else {
                HourglassOpening(true)
            }

            if(session.get("packMethod")) {
                session.set("friendsAdded", PackMethod_RenewFriends())
                SelectPack("HGPack")
                PackOpening()
            }
            else {
                HourglassOpening(true)
            }
        }

        ; Daily Mission 4hg collection and/or extra 3rd pack opening
        if((botConfig.get("deleteMethod") = "Inject Wonderpick 96P+" || botConfig.get("deleteMethod") = "Inject 13P+") && (botConfig.get("claimDailyMission") || botConfig.get("openExtraPack"))) {

            ; If only claiming daily missions (no extra pack)
            if(botConfig.get("claimDailyMission") && !botConfig.get("openExtraPack")) {
                GoToMain()
                doSpecial := (botConfig.get("claimSpecialMissions") = 1)
                ClaimAllMissionRewards(true, doSpecial)
            }
            ; If only opening extra pack (no daily mission claim)
            else if(!botConfig.get("claimDailyMission") && botConfig.get("openExtraPack")) {
                ; Remove & add friends between 2nd free pack & HG pack if 1-pack method is enabled
                if(session.get("packMethod")) {
                    session.set("friendsAdded", PackMethod_RenewFriends())
                    if (!PackMethod_ConsumeStayOnPackScreen()) {
                        GoToMain()
                        SelectPack("HGPack")
                    }
                }
                if(!session.get("cantOpenMorePacks")) {
                    HourglassOpening(true)
                }
            }
            ; If both settings are enabled (original functionality)
            else if(botConfig.get("claimDailyMission") && botConfig.get("openExtraPack")) {
                ; Remove & add friends between 2nd free pack & HG pack if 1-pack method is enabled
                if(session.get("packMethod")) {
                    session.set("friendsAdded", PackMethod_RenewFriends())
                }

                GoToMain()
                doSpecial := (botConfig.get("claimSpecialMissions") = 1)
                ClaimAllMissionRewards(true, doSpecial)
                GoToMain()
                SelectPack("HGPack")
                if(!session.get("cantOpenMorePacks")) {
                    PackOpening()
                }
            }
        }

        MidOfRun:

        if(botConfig.get("deleteMethod") = "Inject 13P+" || botConfig.get("deleteMethod") = "Inject Missions" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum"))
            Goto, EndOfRun

        if (checkShouldDoMissions()) {
            GoToMain()
            HomeAndMission()
            if(session.get("missionDoneList")["beginnerMissionsDone"])
                Goto, EndOfRun

            SelectPack("HGPack")
            PackOpening() ;6
            if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
                Goto, EndOfRun

            HourglassOpening(true) ;7
            if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
                Goto, EndOfRun

            GoToMain()
            HomeAndMission()
            if(session.get("missionDoneList")["beginnerMissionsDone"])
                Goto, EndOfRun

            SelectPack("HGPack")
            PackOpening() ;8
            if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
                Goto, EndOfRun

            HourglassOpening(true) ;9
            if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
                Goto, EndOfRun
            HourglassOpening(true) ;10
            if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
                Goto, EndOfRun

            HourglassOpening(true) ;11
            if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
                Goto, EndOfRun

            HourglassOpening(true) ;12
            if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
                Goto, EndOfRun

            GoToMain()
            SelectPack("HGPack")
            PackOpening() ;13
            if(session.get("cantOpenMorePacks") || (!session.get("friendIDs") && botConfig.get("FriendID") = "" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")))
                Goto, EndOfRun

            SetBeginnerMissionsDone()
        }

        EndOfRun:

        ; For Inject Rewards: save original file timestamp to restore it after setMetaData calls
        claimRewardsOrigTime := ""
        if (botConfig.get("deleteMethod") = "Inject Rewards" && session.get("injectMethod") && session.get("loadedAccount")) {
            claimRewardsSaveDir := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName")
            FileGetTime, claimRewardsOrigTime, % claimRewardsSaveDir . "\" . session.get("accountFileName"), M
        }

        accountMeta := ""
        if (session.get("injectMethod") && session.get("loadedAccount") && session.get("accountFileName") != "") {
            accountMetaPath := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName") . "\" . session.get("accountFileName")
            accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), accountMetaPath)
        }

        if(botConfig.get("wonderpickForEventMissions") && (!IsObject(accountMeta) || AccountEligibility_FlagIsExpired(accountMeta, "W", 24))) {
            GoToMain()
            FindImageAndClick("WonderPick_WonderPickButtonInHome", 59, 429) ;click until in wonderpick Screen
            DoWonderPickOnly()
        }

        ; Daily + Special missions - unified single-pass claim
        method := botConfig.get("deleteMethod")
        doDaily := (method = "Inject Rewards" && botConfig.get("claimDailyMission"))
        doSpecial := (botConfig.get("claimSpecialMissions") = 1 && !session.get("missionDoneList")["specialMissionsDone"] && (method = "Inject 13P+" || method = "Inject Wonderpick 96P+" || method = "Inject Rewards"))
        if (doDaily || doSpecial) {
            GoToMain()
            ClaimAllMissionRewards(doDaily, doSpecial, accountMeta)
        }

        forceGift := session.get("forceReceiveGiftThisRun")
        if(!session.get("missionDoneList")["receivedGiftDone"] && botConfig.get("receiveGift") && session.get("injectMethod") && (forceGift || !IsObject(accountMeta) || !AccountEligibility_FlagIsSet(accountMeta, "R"))) {
            GoToMain()
            if (isTerminatePTCGPHelperApp()) {
                InitPackOpening(true)
            }
            session.set("openedGiftPack", false)
            giftClaimed := ReceiveGiftExtended()
            if(giftClaimed) {
                HandleGiftedPacksAfterReceiveGift()
            }
            if (session.get("openedGiftPack") = true) {
                CheckPack(true)
            } else {
                TerminateHelper()
            }
            session.get("missionDoneList")["receivedGiftDone"] := 1
            session.set("forceReceiveGiftThisRun", 0)

            if (session.get("injectMethod") && session.get("loadedAccount"))
                setMetaData()
        }

        ; Hourglass spending
        if (botConfig.get("spendHourGlass") = 1 && !(botConfig.get("deleteMethod") = "Inject 13P+" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")) && botConfig.get("deleteMethod") != "Inject Rewards" && botConfig.get("deleteMethod") != "Rename Account") {
            SpendAllHourglass()
        }

        if(botConfig.get("ocrShinedust") && session.get("injectMethod") && session.get("loadedAccount")) {
            CountShinedust()
        }

        ; Friend removal for Inject Wonderpick 96P+
        if (session.get("injectMethod") && session.get("friended") && !session.get("keepAccount")) {
            RemoveFriends()
        }

        ; Showcase likes
        botConfig.loadIniSectionFromSettingsFile("Extra")
        if (botConfig.get("showcaseLikes") > 0 && botConfig.get("showcaseEnabled") = 1) {
            showcaseNumber := botConfig.get("showcaseLikes") - 1
            botConfig.set("showcaseLikes", showcaseNumber, "Extra")
            botConfig.saveConfigToSettings("Extra")

            FindImageAndClick("Common_ActivatedSocialInMainMenu", 143, 518, , 500)
            showcaseLikes()
        }

        if (session.get("friended")) {
            CreateStatusMessage("Unfriending...",,,, false)
            RemoveFriends()
        }

        ; BallCity 2025.02.21 - Track monitor
        now := A_NowUTC
        IniWrite, %now%, % session.get("scriptIniFile"), Metrics, LastEndTimeUTC
        EnvSub, now, 1970, seconds
        IniWrite, %now%, % session.get("scriptIniFile"), Metrics, LastEndEpoch

        session.set("rerolls", session.get("rerolls") + 1)
        session.set("rerolls_local", session.get("rerolls_local") + 1)
        IniWrite, % session.get("rerolls"), % session.get("scriptIniFile"), Metrics, rerolls

        totalSeconds := Round((A_TickCount - session.get("rerollStartTime")) / 1000) ; Total time in seconds
        totalSeconds_local := Round((A_TickCount - session.get("rerollStartTime_local")) / 1000) ; Total time in seconds
        session.set("avgtotalSeconds", Round(totalSeconds_local / session.get("rerolls_local"))) ; Total time in seconds
        session.set("aminutes", Floor(session.get("avgtotalSeconds") / 60)) ; Average minutes
        session.set("aseconds", Mod(session.get("avgtotalSeconds"), 60)) ; Average remaining seconds
        updateTotalTime()

        session.set("VRAMUsage", GetVRAMByScriptName(session.get("scriptName")))

        ; Add total time, Logging.ahk #31: guiheight := 30

        ; Display the times
        CreateStatusMessage(generateStatusText(), "AvgRuns", 0, 605, false, true)

        ; Log to file
        LogInfo("Packs: " . session.get("packsThisRun") . " | Total time: " . session.get("mminutes") . "m " . session.get("sseconds") . "s | Avg: " . session.get("aminutes") . "m " . session.get("aseconds") . "s | Runs: " . session.get("rerolls"))

        SendMetadataToPTCGPB(session.get("packsThisRun"))

        ; Check for 40 first to quit
        if (botConfig.get("deleteMethod") = "Inject 13P+" && session.get("accountOpenPacks") >= session.get("maxAccountPackNum")) {
            if (session.get("injectMethod") && session.get("loadedAccount")) {
                if (!session.get("keepAccount") || session.get("s4tFoundTradeable")) {
                    MarkAccountAsUsed()
                }
                session.set("loadedAccount", false)
                continue
            }
        }

        if (session.get("injectMethod") && session.get("loadedAccount")) {
            ; For injection methods, mark the account as used
            if (!session.get("keepAccount") || session.get("s4tFoundTradeable")) {
                if ((botConfig.get("deleteMethod") = "Inject Rewards" || botConfig.get("deleteMethod") = "Rename Account") && !session.get("s4tFoundTradeable")) {
                    MarkAccountAsClaimed()  ; No 24h lock — account stays available for pack-opening
                    LogDebug("Marked injected account as claimed: " . session.get("accountFileName"))
                } else {
                    MarkAccountAsUsed()  ; Remove account from queue
                    LogDebug("Marked injected account as used: " . session.get("accountFileName"))
                }
            } else {
                LogDebug("Keeping injected account: " . session.get("accountFileName"))
            }

            ; Reset loadedAccount so it will be loaded fresh next iteration
            session.set("loadedAccount", false)
        } else if (!session.get("injectMethod")) {
            if ((!session.get("injectMethod") || !session.get("loadedAccount"))) {
                ; Save account for Create Bots
                ; At end of Create Bots run - check if we already have XML from tradeables
                deviceAccount := GetDeviceAccountFromXML()

                if (session.get("deviceAccountXmlMap").HasKey(deviceAccount) && FileExist(session.get("deviceAccountXmlMap")[deviceAccount])) {
                    ; We already have an XML from tradeable finds - update it in place.
                    existingXmlPath := session.get("deviceAccountXmlMap")[deviceAccount]

                    ; Update XML with final account state
                    UpdateSavedXml(existingXmlPath)

                    SplitPath, existingXmlPath, oldFileName, saveDir
                    accountMeta := AccountMetadata_Get(session.get("scriptName"), oldFileName, existingXmlPath)
                    if (session.get("creationDate") != "")
                        accountMeta["createdAt"] := session.get("creationDate")
                    accountMeta["packCount"] := session.get("accountOpenPacks") + 0
                    flags := {"B": session.get("missionDoneList")["beginnerMissionsDone"]
                        , "X": session.get("missionDoneList")["specialMissionsDone"]
                        , "T": session.get("missionDoneList")["accountHasPackInTesting"]
                        , "R": session.get("missionDoneList")["receivedGiftDone"]}
                    for flag, value in flags {
                        if (!accountMeta["flags"].HasKey(flag))
                            accountMeta["flags"][flag] := AccountMetadata_NewFlag(0)
                        oldValue := accountMeta["flags"][flag]["value"]
                        accountMeta["flags"][flag]["value"] := value ? 1 : 0
                        if (oldValue != accountMeta["flags"][flag]["value"])
                            accountMeta["flags"][flag]["setAt"] := value ? AccountMetadata_Now() : ""
                    }
                    AccountMetadata_SaveAccount(session.get("scriptName"), oldFileName, accountMeta)

                    ; Update mapping and accountFileName
                    session.get("deviceAccountXmlMap")[deviceAccount] := existingXmlPath
                    session.set("accountFileName", oldFileName)

                } else {
                    ; No tradeable XML exists - create new one normally
                    savedXmlPath := ""
                    saveAccount("All", savedXmlPath)

                    if (savedXmlPath) {
                        SplitPath, savedXmlPath, xmlFileName
                        session.set("accountFileName", xmlFileName)
                    }
                }

                EnsureAccountLanguageMetadata()

                if (botConfig.get("deleteMethod") = "Create Bots (13P)" && IsFunc("EnsureAccountFriendInfo"))
                    EnsureAccountFriendInfo("Create Bots (13P)", false, true)

                ; if Create Bots + FoundTradeable, log to database and push discord webhook message(s)
                if (!session.get("loadDir") && session.get("s4tPendingTradeables").Length() > 0) {
                    ProcessPendingTradeables()
                }

                session.get("missionDoneList")["beginnerMissionsDone"] := 0
                session.get("missionDoneList")["specialMissionsDone"] := 0
                session.get("missionDoneList")["accountHasPackInTesting"] := 0

                restartGameInstance("New Run", false)
            } else {
                if (session.get("stopToggle")) {
                    CreateStatusMessage("Stopping...",,,, false)
                    CleanupBeforeExit()
                    ExitApp
                }
                restartGameInstance("New Run", false)
            }
        }
    }
}

return

FindOrLoseImage(needleName := "DEFAULT", EL := 1, safeTime := 0, searchVariation := 20, notShowFinding := 0, coordImageName := "", coordEL := "", coordSafeTime := "") {
    prof := Prof_Scope(A_ThisFunc)
    profNeedle := Prof_Scope(A_ThisFunc . ":" . needleName)
    global botConfig, session, needlesDict
    static lastStatusTime := 0

    coordinateMode := (coordImageName != "")
    if (coordinateMode) {
        X1 := needleName
        Y1 := EL
        X2 := safeTime
        Y2 := searchVariation
        imageName := coordImageName
        searchVariation := (notShowFinding = "" || notShowFinding = 0) ? 20 : notShowFinding
        EL := (coordEL = "") ? 1 : coordEL
        safeTime := (coordSafeTime = "") ? 0 : coordSafeTime
        notShowFinding := 0
    } else {
        needleObj := needlesDict.Get(needleName)
        imageName := needleObj.imageName
    }

    if(botConfig.get("slowMotion")) {
        if(IsSpeedModImageName(imageName))
            return true
    }
    imagePath := A_ScriptDir . "\Needles\"
    confirmed := false

    if(A_TickCount - lastStatusTime > 500 and !notShowFinding) {
        lastStatusTime := A_TickCount
        CreateStatusMessage("Finding " . imageName . "...")
    }

    pBitmap := from_window(getMuMuHwnd(session.get("winTitle")))
    Path = %imagePath%%imageName%.png
    pNeedle := GetNeedle(Path)

    if (!coordinateMode) {
        X1 := needleObj.coords.startX
        Y1 := needleObj.coords.startY
        X2 := needleObj.coords.endX
        Y2 := needleObj.coords.endY
    }

    ; ImageSearch within the region
    vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, X1, Y1, X2, Y2, searchVariation)
    if(EL = 0)
        GDEL := 1
    else
        GDEL := 0
    if (!confirmed && vRet = GDEL && GDEL = 1) {
        confirmed := vPosXY
    } else if(!confirmed && vRet = GDEL && GDEL = 0) {
        confirmed := true
    }

    if (imageName = "CommunityShowcase" || imageName = "Search" || imageName = "inHamburgerMenu" || imageName = "Trade") {
        Path = %imagePath%Tutorial.png
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 111, 115, 167, 121, searchVariation)
        if (vRet = 1) {
            adbClick_wbb(145, 451)
        }
    }

    if (isTerminatePTCGPAppByADBShell()) {
        Gdip_DisposeImage(pBitmap)
        TriggerGameRestart("Stuck at " . imageName . "... (App terminated)")
        return confirmed
    }

    if(imageName = "Missions") { ; may input extra ESC and stuck at exit game
        Path = %imagePath%Delete2.png
        pNeedle := GetNeedle(Path)
        ; ImageSearch within the region
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 118, 353, 135, 390, searchVariation)
        if (vRet = 1) {
            adbClick_wbb(74, 353)
            Delay(1)
        }
    }
/*
if(imageName = "CommunityShowcase") {
    TradeTutorialForShowcase()
}
*/

    ErrorCheckInScreen(pBitmap)

    if(imageName = "Social" || imageName = "Country" || imageName = "Account2" || imageName = "Account" || imageName = "Points") { ;only look for deleted account on start up.
        Path = %imagePath%NoSave.png ; look for No Save Data error message > if loaded account > delete xml > reload
        pNeedle := GetNeedle(Path)
        ; ImageSearch within the region
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 30, 331, 50, 449, searchVariation)
        if (vRet = 1) {
            adbWriteRaw("rm -rf /data/data/jp.pokemon.pokemontcgp/cache/*") ; clear cache
            waitadb()
            CreateStatusMessage("Loaded deleted account. Deleting XML...",,,, false)
            if(session.get("loadedAccount")) {
                FileDelete, % session.get("loadedAccount")
                IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck
            }
            LogInfo("Restarted game. Reason: No save data found")
            CleanupBeforeExit()
            SafeReload("No save data found")
        }
    }

    ;country for new accounts, social for inject with friend id, points for inject without friend id
    if(imageName = "Country" || imageName = "Social" || imageName = "Points")
        FSTime := 90
    else if(imageName = "Missions" || imageName = "DailyMissions" || imageName = "DexMissions")
        FSTime := 60
    else
        FSTime := 45
    if (safeTime >= FSTime) {
        if(session.get("injectMethod") && session.get("loadedAccount") && session.get("friended")) {
            IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
        }
        restartGameInstance("Stuck at " . imageName . "...")
        session.set("failSafe", A_TickCount)
    }
    Gdip_DisposeImage(pBitmap)
    return confirmed
}

FindImageAndClick(needleName := "DEFAULT", clickx := 0, clicky := 0, searchVariation := 20, sleepTime := "", skip := false, safeTime := 0) {
    prof := Prof_Scope(A_ThisFunc)
    profNeedle := Prof_Scope(A_ThisFunc . ":" . needleName)
    global botConfig, session, needlesDict

    needleObj := needlesDict.Get(needleName)
    imageName := needleObj.imageName

    if(botConfig.get("slowMotion")) {
        if(IsSpeedModImageName(imageName))
            return true
    }
    if (sleepTime = "") {
        sleepTime := botConfig.get("Delay")
    }
    imagePath := A_ScriptDir . "\Needles\"
    click := false
    if(clickx > 0 and clicky > 0)
        click := true
    x := 0
    y := 0
    session.set("StartSkipTime", A_TickCount)

    confirmed := false

    if(click) {
        adbClick_wbb(clickx, clicky)
        clickTime := A_TickCount
    }
    CreateStatusMessage("Finding and clicking " . imageName . "...")

    messageTime := 0
    firstTime := true
    Loop { ; Main loop
        Sleep, 100
        if(click) {
            ElapsedClickTime := A_TickCount - clickTime
            if(ElapsedClickTime > sleepTime) {
                adbClick_wbb(clickx, clicky)
                clickTime := A_TickCount
            }
        }

        if (confirmed) {
            continue
        }

        pBitmap := from_window(getMuMuHwnd(session.get("winTitle")))
        Path = %imagePath%%imageName%.png
        pNeedle := GetNeedle(Path)
        ; ImageSearch within the region
        X1 := needleObj.coords.startX
        Y1 := needleObj.coords.startY
        X2 := needleObj.coords.endX
        Y2 := needleObj.coords.endY
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, X1, Y1, X2, Y2, searchVariation)
        if (!confirmed && vRet = 1) {
            confirmed := vPosXY
        } else {
            ElapsedTime := (A_TickCount - session.get("StartSkipTime")) // 1000
            if(imageName = "Country" || imageName = "Social" || imageName = "Points")
                FSTime := 90
            else if(imageName = "Missions" || imageName = "DailyMissions" || imageName = "DexMissions")
                FSTime := 60
            else if(imageName = "Proceed") ; Decrease time for Marowak
                FSTime := 8
            else if(imageName = "OpeningMultiple") ; Increase time for 10 pulls
                FSTime := 300 ; based on user reports it takes around 2 minutes on average with no immersive and every special effect increases it. 3-4 minutes seems to be sufficient for the average run, 5 minutes should be for the worst case
            else
                FSTime := 45
            if(!skip) {
                if(ElapsedTime - messageTime > 0.5 || firstTime) {
                    CreateStatusMessage("Looking for " . imageName . " for " . ElapsedTime . "/" . FSTime . " seconds")
                    messageTime := ElapsedTime
                    firstTime := false
                }
            }
            if (ElapsedTime >= FSTime || safeTime >= FSTime) {
                CreateStatusMessage("Instance " . session.get("scriptName") . " has been stuck for 90s. Killing it...")
                if(session.get("injectMethod") && session.get("loadedAccount") && session.get("friended")) {
                    IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
                }
                restartGameInstance("Stuck at " . imageName . "...") ; change to reset the instance and delete data then reload script
            }
        }

        ErrorCheckInScreen(pBitmap)

        if (imageName = "CommunityShowcase" || imageName = "Add" || imageName = "Search") {
            Path = %imagePath%Tutorial.png
            pNeedle := GetNeedle(Path)
            vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 111, 115, 167, 121, searchVariation)
            if (vRet = 1) {
                adbClick_wbb(145, 451)
            }
        }

        if (isTerminatePTCGPAppByADBShell()) {
            Gdip_DisposeImage(pBitmap)
            TriggerGameRestart("Stuck at " . imageName . "... (App terminated)")
            return false
        }

        if(imageName = "Social" || imageName = "Country" || imageName = "Account2" || imageName = "Account") { ;only look for deleted account on start up.
            Path = %imagePath%NoSave.png ; look for No Save Data error message > if loaded account > delete xml > reload
            pNeedle := GetNeedle(Path)
            ; ImageSearch within the region
            vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 30, 331, 50, 449, searchVariation)
            if (vRet = 1) {
                adbWriteRaw("rm -rf /data/data/jp.pokemon.pokemontcgp/cache/*") ; clear cache
                waitadb()
                CreateStatusMessage("Loaded deleted account. Deleting XML...",,,, false)
                if(session.get("loadedAccount")) {
                    FileDelete, % session.get("loadedAccount")
                    IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck
                }
                LogInfo("Restarted game. Reason: No save data found")
                CleanupBeforeExit()
                SafeReload("No save data found")
            }
        }

        if(imageName = "Skip2" || imageName = "Pack" || imageName = "Hourglass2") {
            Path = %imagePath%notenoughitems.png
            pNeedle := GetNeedle(Path)
            vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 92, 299, 115, 317, 0)
            if(vRet = 1) {
                session.set("cantOpenMorePacks", 1)
                return 0
            }
        }

        if(imageName = "Mission_dino2" || imageName = "Mission_dino3") {
            Path = %imagePath%1solobattlemission.png
            pNeedle := GetNeedle(Path)
            vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 108, 180, 177, 208, 0)
            if(vRet = 1) {
                SetBeginnerMissionsDone()
                return
            }
        }

        Gdip_DisposeImage(pBitmap)
/*
if(imageName = "CommunityShowcase") {
    TradeTutorialForShowcase()
}
*/

        if(skip) {
            ElapsedTime := (A_TickCount - session.get("StartSkipTime")) // 1000
            if(ElapsedTime - messageTime > 0.5 || firstTime) {
                CreateStatusMessage("Looking for " . imageName . "`nSkipping in " . (skip - ElapsedTime) . " seconds...")
                messageTime := ElapsedTime
                firstTime := false
            }
            if (ElapsedTime >= skip) {
                confirmed := false
                ElapsedTime := ElapsedTime/2
                break
            }
        }
        if (confirmed) {
            break
        }
    }
    Gdip_DisposeImage(pBitmap)
    return confirmed
}

resetWindows() {
    prof := Prof_Scope(A_ThisFunc)
    DirectlyPositionWindow()

    return true
}

DirectlyPositionWindow() {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig

    scaleParam := 283
    rowGap := botConfig.get("rowGap")

    ; Get monitor information
    SelectedMonitorIndex := RegExReplace(botConfig.get("SelectedMonitorIndex"), ":.*$")
    SysGet, Monitor, Monitor, %SelectedMonitorIndex%

    ; Calculate position based on instance number
    Title := session.get("winTitle")

    if (botConfig.get("runMain")) {
        instanceIndex := (botConfig.get("Mains") - 1) + Title + 1
    } else {
        instanceIndex := Title
    }

    titleHeight := 40 + MuMuBias()

    borderWidth := 4 - 1
    rowHeight := titleHeight + 492
    currentRow := Floor((instanceIndex - 1) / botConfig.get("Columns"))

    y := MonitorTop + (currentRow * rowHeight) + (currentRow * rowGap)
    x := MonitorLeft + (Mod((instanceIndex - 1), botConfig.get("Columns")) * (scaleParam - borderWidth * 2))

    WinSet, Style, -0xC00000, % "ahk_id " . getMuMuHwnd(session.get("winTitle"))
    WinMove, % "ahk_id " . getMuMuHwnd(session.get("winTitle")), , %x%, %y%, %scaleParam%, %rowHeight%
    WinSet, Style, +0xC00000, % "ahk_id " . getMuMuHwnd(session.get("winTitle"))
    WinSet, Redraw, , % "ahk_id " . getMuMuHwnd(session.get("winTitle"))

    FixInstanceScreen(session.get("winTitle"))

    CreateStatusMessage("Positioned window at x:" . x . " y:" . y,,,, false)

    return true
}

restartGameInstance(reason, RL := true) {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig, session, DeadCheck
    isStuck := InStr(reason, "Stuck")

    if (Debug)
        CreateStatusMessage("Restarting game reason:`n" . reason)
    else if (isStuck)
        CreateStatusMessage("Stuck! Restarting MuMu...",,,, false)
    else
        CreateStatusMessage("Restarting game...",,,, false)

    ; Log to instance-specific log file
    if (isStuck) {
        logStr := "STUCK DETECTED - Reason: " . reason . " | injectMethod: " . (session.get("injectMethod") ? "true" : "false") . " | "
        logStr .= "loadedAccount: " . (session.get("loadedAccount") ? "true" : "false") . " | "
        logStr .= "accountFileName: " . session.get("accountFileName")
        LogInfo(logStr)
        SaveStuckScreenshot(reason)
        ; Persist recovery state before any stuck-triggered restart.
        ; This guarantees startup recovery removes friends before loading a new account.
        if (session.get("injectMethod") && session.get("loadedAccount") && session.get("friended")) {
            IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
            SetFriendCleanupPending("Stuck recovery: " . reason)
            LogInfo("Friend cleanup pending set for stuck recovery. Reason: " . reason, "GroupReroll.txt")
        }
    }

    if (RL = "GodPack") {
        LogInfo("Restarted game. Reason: " reason)
        IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck
        ClearFriendCleanupPending()
        if (!botConfig.get("groupRerollEnabled"))
            AppendFriendCodeToManualVipIds(session.get("friendCode"))
        SendMetadataToPTCGPB(session.get("packsThisRun"))

        PersistStopAfterRunIfNeeded()
        CleanupBeforeExit()
        SafeReload("GodPack restart")
    } else if (isStuck) {
        if(!checkInstance(session.get("scriptName"))){
            LogInfo(" Found " . session.get("scriptName") . " instance down! start Instance")
            launchInstance(session.get("scriptName"))
        }

        ; For a detected stuck state, restart only the Pocket app through ADB.
        ; The external Monitor handles full MuMu instance recovery if needed.
        CreateStatusMessage("Restarting Pocket App...",,,, false)
        LogInfo("Restarting Pocket App " . session.get("scriptName") . " due to: " . reason)
        ;restartInstance()
        closePTCGPApp()
        Sleep, 100
        AccountMetadata_CloseTempForInstance(session.get("scriptName"))
        startPTCGPApp()
        SendMetadataToPTCGPB(session.get("packsThisRun"))
        LogInfo("Restarted MuMu instance. Reason: " reason)

        PersistStopAfterRunIfNeeded()
        CleanupBeforeExit()
        SafeReload("Stuck restart: " . reason)
    } else {
        ; Non-stuck restart: just restart the Pokemon app, not the whole MuMu instance
        closePTCGPApp()
        AccountMetadata_CloseTempForInstance(session.get("scriptName"))
        Sleep, 100

        if (!RL && DeadCheck = 0) {
            adbWriteRaw("rm -f /data/data/jp.pokemon.pokemontcgp/shared_prefs/deviceAccount:.xml") ; delete account data
        }
        Sleep, 100
        AccountMetadata_CloseTempForInstance(session.get("scriptName"))
        startPTCGPApp()

        if (RL) {
            LogInfo("Restarted game. Reason: " reason)

            PersistStopAfterRunIfNeeded()
            CleanupBeforeExit()
            SafeReload("Restart game: " . reason)
        }

        if (session.get("stopToggle")) {
            CreateStatusMessage("Stopping...",,,, false)
            CleanupBeforeExit()
            ExitApp
        }
    }
}

ControlClick(X, Y) {
    global session
    ControlClick, x%X% y%Y%, % session.get("winTitle")
}

; Pause Script
PauseScript:
    CreateStatusMessage("Pausing...",,,, false)
    g_scriptPaused := true
    Pause, On, 1
return

; Resume Script
ResumeScript:
    CreateStatusMessage("Resuming...",,,, false)
    session.set("StartSkipTime", A_TickCount) ;reset stuck timers
    session.set("failSafe", A_TickCount)
    g_scriptPaused := false
    Pause, Off
return

TogglePauseScript:
    if (g_scriptPaused) {
        CreateStatusMessage("Resuming...",,,, false)
        session.set("StartSkipTime", A_TickCount) ;reset stuck timers
        session.set("failSafe", A_TickCount)
        g_scriptPaused := false
        Pause, Off
    } else {
        CreateStatusMessage("Pausing...",,,, false)
        g_scriptPaused := true
        Pause, On, 1
    }
return

; Stop Script
StopScript:
    ToggleStop()
return

DevMode:
    ToggleDevMode()
return

ReloadScript:
    CleanupBeforeExit()
    SafeReload("Toolbar reload")
return

TestScript:
    ToggleTestScript()
return

; === Single instance stop handlers (GUI button) ===
StopImmediatelySingle:
    targetHwnd := session.get("RememberStopPreferenceSingleHwnd")
    GuiControlGet, RememberStopPreferenceSingle, , %targetHwnd%
    if (RememberStopPreferenceSingle) {
        botConfig.set("stopPreferenceSingle", "immediate", "Extra")
        botConfig.saveConfigToSettings("Extra")
    }
    Gui, StopConfirm:Destroy
    CleanupBeforeExit()
    ExitApp
return

StopWaitEndSingle:
    Gui, StopConfirm:Submit, NoHide
    GuiControlGet, RememberStopPreferenceSingle, , ui_RememberStopPreferenceSingle
    if (RememberStopPreferenceSingle) {
        botConfig.set("stopPreferenceSingle", "wait_end", "Extra")
        botConfig.saveConfigToSettings("Extra")
    }
    Gui, StopConfirm:Destroy
    session.set("stopToggle", true)
    CreateStatusMessage("Stopping script at the end of the run...",,,, false)
return

StopConfirmGuiClose:
StopConfirmGuiEscape:
    Gui, StopConfirm:Destroy
return

; === All instances stop handlers (Shift+F7 from instance 1) ===
StopImmediatelyAll:
    targetHwnd := session.get("RememberStopPreferenceHwnd")
    GuiControlGet, RememberStopPreference, , %targetHwnd%
    if (RememberStopPreference) {
        botConfig.set("stopPreference", "immediate", "Extra")
        botConfig.saveConfigToSettings("Extra")
    }
    Gui, StopConfirmAll:Destroy
    StopAllInstances()
return

StopWaitEndAll:
    targetHwnd := session.get("RememberStopPreferenceHwnd")
    GuiControlGet, RememberStopPreference, , %targetHwnd%
    if (RememberStopPreference) {
        botConfig.set("stopPreference", "wait_end", "Extra")
        botConfig.saveConfigToSettings("Extra")
    }
    Gui, StopConfirmAll:Destroy
    ; Signal all other instances to stop after their current run
    SignalStopAfterRun()
    session.set("stopToggle", true)
    CreateStatusMessage("Stopping script at the end of the run...",,,, false)
return

StopAndKillMuMuAll:
    GuiControlGet, RememberStopPreference, , ui_RememberStopPreference
    Gui, StopConfirmAll:Submit, NoHide
    if (RememberStopPreference) {
        settingsPath := A_ScriptDir . "\..\Settings.ini"
        IniWrite, kill_mumu, %settingsPath%, UserSettings, stopPreference
    }
    Gui, StopConfirmAll:Destroy
    ; Kill ALL MuMu instances before calling StopAllInstances (which does ExitApp)
    Loop, % botConfig.get("Instances") {
        killInstance(A_Index)
        Sleep, 500
    }
    Sleep, 1000
    StopAllInstances()
return

StopConfirmAllGuiClose:
StopConfirmAllGuiEscape:
    Gui, StopConfirmAll:Destroy
return

; ===== TIMER FUNCTIONS =====
RefreshAccountLists:
    createAccountList(session.get("scriptName"))
Return

CleanupUsedAccountsTimer:
    CleanupUsedAccounts()
Return

LiveMetricsTimer:
    updateTotalTime()
    session.set("VRAMUsage", GetVRAMByScriptName(session.get("scriptName")))
    CreateStatusMessage(generateStatusText(), "AvgRuns", 0, 605, false, true)
Return

; ===== HOTKEYS =====
~+F5::
    CleanupBeforeExit()
    SafeReload("Shift+F5")
return
~+F6::
    Gosub, TogglePauseScript
return
~+F7::
    ; Only instance 1 handles Shift+F7 - shows popup and controls all instances
    ; Other instances do nothing here; they receive commands via PostMessage from instance 1
    if (session.get("scriptName") = "1") {
        ToggleStopAll()
    }
return
~+F8::ToggleDevMode()
;~F9::restartGameInstance("F9")

; ===== RECORDER HOTKEY =====
; Fires on every left-click; no-op unless recording is active.
/*
~+LButton::
    if (!rec_Active) {
        return
    }
    if (rec_SuspendCapture) {
        return
    }
    MouseGetPos, rec_DownX, rec_DownY, clickedHwnd
    if (clickedHwnd != WinExist(session.get("winTitle"))) {
        return
    }
    CoordMode, Mouse, Screen
    MouseGetPos, rec_DownX, rec_DownY
    CoordMode, Mouse, Relative

    rec_DownTime := A_TickCount
    KeyWait, LButton

    CoordMode, Mouse, Screen
    MouseGetPos, upX, upY
    CoordMode, Mouse, Relative
    held := A_TickCount - rec_DownTime

    ; Compute window-relative coords first, then use them for distance
    WinGetPos, wx, wy, ww, wh, % session.get("winTitle")
    devX1 := rec_DownX - wx
    devY1 := rec_DownY - wy
    devX2 := upX - wx
    devY2 := upY - wy

    ; Ignore clicks that started outside the emulator window
    if (devX1 < 0 || devY1 < 0 || devX1 > ww || devY1 > wh) {
        return
    }

    dist := Sqrt((devX2 - devX1) ** 2 + (devY2 - devY1) ** 2)

    if (dist > 20)
        type := "swipe"
    else if (held >= 500)
        type := "hold"
    else
        type := "click"

    ssPath := RecordingCapture()
    rawDelay := A_TickCount - rec_LastTime - held
    delay := (rawDelay > 0) ? rawDelay // Delay : 0
    rec_LastTime := A_TickCount
    actionIdx := rec_Actions.Length() + 1
    LogDebug("[Hook] Pushing action idx=" actionIdx " type=" type " x1=" devX1 " y1=" devY1 " x2=" devX2 " y2=" devY2 " ssPath=" ssPath, "recorder.txt")
    rec_Actions.Push({type: type, x1: devX1, y1: devY1, x2: devX2, y2: devY2
        , duration: held, delay: delay, screenshot: ssPath, comment: "", code: ""})
    LogDebug("[Hook] rec_Actions.Length()=" rec_Actions.Length() " last.screenshot=" rec_Actions[rec_Actions.Length()].screenshot, "recorder.txt")
    CreateStatusMessage("Recording: Capture`n" type " (" devX1 "," devY1 ")-(" devX2 "," devY2 ") dist=" dist)
return
*/
screenshotscript:
    if (rec_Active) {
        rawDelay := A_TickCount - rec_LastTime
        delay := (rawDelay > 0) ? rawDelay // botConfig.get("Delay") : 0
        rec_SuspendCapture := true
        CreateStatusMessage("Recording: Capture`nYou could deside what to do with it later.")
        rec_LastScreenGrab := ""
        Screenshot_dev()
        rec_SuspendCapture := false
        if (rec_LastScreenGrab != "") {
            rec_Actions.Push({type: "screenshot"
                , fileName:       rec_LastScreenGrab.fileName
                , needlePath:     rec_LastScreenGrab.needlePath
                , screenshot:     rec_LastScreenGrab.screenshot
                , x1: rec_LastScreenGrab.x1, y1: rec_LastScreenGrab.y1
                , x2: rec_LastScreenGrab.x2, y2: rec_LastScreenGrab.y2
                , x3: rec_LastScreenGrab.x3, y3: rec_LastScreenGrab.y3
                , delay: delay, screenshot: rec_LastScreenGrab.needlePath
                , comment: "", code: "", choice: ""})
            rec_LastTime := A_TickCount
            CreateStatusMessage("Recording: Image captured")
        } else {
            CreateStatusMessage("")
        }
    } else {
        Screenshot_dev()
    }
return

Logout:
    closePTCGPApp()
    adbWriteRaw("rm /data/data/jp.pokemon.pokemontcgp/shared_prefs/deviceAccount:.xml")
    AccountMetadata_CloseTempForInstance(session.get("scriptName"))
    startPTCGPApp()
return

bboxScript:
    ToggleBBox()
return

bboxNpauseScript:
    TogglebboxNpause()
return

Gdip_ImageSearch_wbb(pBitmapHaystack,pNeedle,ByRef OutputList=""
    ,OuterX1=0,OuterY1=0,OuterX2=0,OuterY2=0,Variation=0,Trans=""
    ,SearchDirection=1,Instances=1,LineDelim="`n",CoordDelim=",") {
    prof := Prof_Scope(A_ThisFunc)
    profNeedle := Prof_Scope(A_ThisFunc . ":" . pNeedle.Name)
    global session

    bias := MuMuBias()

    vret := Gdip_ImageSearch(pBitmapHaystack,pNeedle.needle,OutputList,OuterX1,OuterY1+bias,OuterX2,OuterY2+bias,Variation,Trans,SearchDirection,Instances,LineDelim,CoordDelim)
    if(session.get("dbg_bbox"))
        bboxAndPause_immage(OuterX1, OuterY1+bias, OuterX2, OuterY2+bias, pNeedle, vret, session.get("dbg_bboxNpause"))
    return vret
}

GetNeedle(Path) {
    prof := Prof_Scope(A_ThisFunc)
    static NeedleBitmaps := Object()

    if (NeedleBitmaps.HasKey(Path)) {
        return NeedleBitmaps[Path]
    } else {
        pNeedle := Gdip_CreateBitmapFromFile(Path)
        needleObj := Object()
        needleObj.Path := Path
        pathsplit := StrSplit(Path , "\")
        needleObj.Name := pathsplit[pathsplit.MaxIndex()]
        needleObj.needle := pNeedle
        NeedleBitmaps[Path] := needleObj
        return needleObj
    }
}

GoToMain() {
    global session

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop, {
        ; 1.7.0: tutorials during GoToMain always force an app restart onto Welcome.
        ; ESC on Welcome opens quit confirmation — Cancel (if needed) + Tap to Start.
        if (FindOrLoseImage("Create_WelcomePopup", 0, 0, , true)
            || FindOrLoseImage("Boot_Welcome", 0, 0, , true)
            || FindOrLoseImage("Boot_Welcome2", 0, 0, , true)) {
            if (FindOrLoseImage("Common_CloseAlertWindowInMain", 0, 0, , true)) {
                adbClick_wbb(75, 365) ; Cancel quit dialog
                Delay(1)
            }
            adbClick_wbb(140, 450) ; Tap to Start
            Delay(2)
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            CreateStatusMessage("Moving to Main`n(tap Welcome after restart)")
            continue
        }

        ; Quit dialog covering Welcome (needle may not see Welcome behind it).
        if (FindOrLoseImage("Common_CloseAlertWindowInMain", 0, 0, , true)
            && !FindOrLoseImage("Common_ActivatedHomeInMainMenu", 0, 0, , true)) {
            adbClick_wbb(75, 365) ; Cancel
            Delay(1)
            adbClick_wbb(140, 450) ; Tap to Start
            Delay(2)
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            CreateStatusMessage("Moving to Main`n(cancel quit after restart)")
            continue
        }

        if(FindOrLoseImage("Common_CloseAlertWindowInMain", 0, failSafeTime, , true) && FindOrLoseImage("Common_ActivatedHomeInMainMenu", 0, failSafeTime, , true)){
            Loop, {
                adbInputEvent("111") ;send ESC
                Delay(3)

                if(FindOrLoseImage("Common_ShopButtonInMain", 0, failSafeTime))
                    break
            }
            break
        }
        else{
            adbInputEvent("111") ;send ESC
        }

        if(FindOrLoseImage("Common_PopupXButtonInMain", 0, , , true)){
            adbClick_wbb(137, 480)
            Delay(1)
        }

        if(FindOrLoseImage("TradeUnlocked", 0, , , true)){
            adbInputEvent("111") ;send ESC
            Delay(1)
        }

        DelayH(600)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Moving to Main`n(" . failSafeTime . "/45 seconds)")
    }
}
