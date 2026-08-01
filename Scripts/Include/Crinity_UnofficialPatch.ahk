; FindOrLoseImage EL = 0, Found Mode, Found image - Return xy pos / Not Found image - Return 0
; FindOrLoseImage EL = 1, Loose Mode, Found image - Return 0 / Not Found image - Return 1
; ====================================================================
; #Include %A_ScriptDir%\Include\Crinity_UnofficialPatch.ahk

processPrivacyAgreement()
{
    if(!FindOrLoseImage("Privacy_Box", 0) || !FindOrLoseImage("Privacy_Box2", 0))
        return

    CreateStatusMessage("Accepting Privacy and TOS popup.",,,, false)
    Delay(2)
    Loop, {
        adbClick(139, 329)
        Delay(2)
        if(FindOrLoseImage("Privacy_Cross", 0))
            break
    }
    Delay(2)
    Loop, {
        adbClick(138, 479)
        Delay(2)
        if(!FindOrLoseImage("Privacy_Cross", 0))
            break
    }
    Delay(2)
    Loop, {
        adbClick(40, 365)
        Delay(2)
        if(FindOrLoseImage("Privacy_Green", 0))
            break
    }
    Delay(1)
    adbClick(138, 479)
}

; True when Finding main UI is visible — Welcome Back is behind us (not Social.png;
; that only appears after the Social tab click in Inject 96P+).
IsFindingMainUiVisible() {
    return FindOrLoseImage("Pack_PackPointButton", 0, , , true)
        || FindOrLoseImage("Common_ActivatedHomeInMainMenu", 0, , , true)
        || FindOrLoseImage("Friend_BottomDarkHomeIcon", 0, , , true)
        || FindOrLoseImage("Common_ShopButtonInMain", 0, , , true)
        || FindOrLoseImage("WonderPick_WonderPickButtonInHome", 0, , , true)
}

; Welcome Back appears AFTER Welcome, while Finding Home/Points/Social.
; Multi-page: sticky Next/OK after page-1 needle until main UI is visible, then stop
; so mode clicks (e.g. Social tab) can run. Do NOT call from boot.
; Returns true when a dismiss click was issued this tick.
TryAdvanceWelcomeBackWhileFinding(logContext, ByRef advancing, ByRef useSecondClick, failSafeTime := 0) {
    if (FindOrLoseImage("Boot_WelcomeBack", 0, 0, 20, true)) {
        if (!advancing)
            LogInfo(logContext . ": Welcome Back during Finding — advancing pages", "ADB.txt")
        advancing := true
        CreateStatusMessage("Dismissing Welcome Back`n(Finding mode target) " . failSafeTime . "/90s",,,, false)
    } else if (advancing && IsFindingMainUiVisible()) {
        ; Needle gone and main UI up — WB finished; release sticky so Social/pack clicks run.
        LogInfo(logContext . ": Welcome Back done (main UI visible) — resume mode click", "ADB.txt")
        advancing := false
        useSecondClick := false
        return false
    }

    if (!advancing)
        return false

    CreateStatusMessage("Dismissing Welcome Back`n(Finding mode target) " . failSafeTime . "/90s",,,, false)

    if (useSecondClick)
        adbClick_wbb(194, 433) ; OK / second-page button
    else
        adbClick_wbb(139, 432) ; Next
    useSecondClick := !useSecondClick
    Sleep, 500
    return true
}

; After first pack, game teleports to Missions: List appears first.
IsWelcomeBackMissionsScreen() {
    return FindOrLoseImage("Mission_ActivatedBeginnerMissionTabButton", 0, 0, , true)
}

; Welcome Back layout shifts the missions sub-tab strip — use (213,463) instead of normal tab clicks.
HasWelcomeBackMissionsLayout() {
    return FindOrLoseImage("Mission_ActivatedBeginnerMissionTabButton", 0, 0, , true)
        && FindOrLoseImage("Mission_WelcomeBackMissions", 0, 0, , true)
}

ClickMissionSubTab(defaultX := 42, defaultY := 465) {
    if (HasWelcomeBackMissionsLayout()) {
        adbClick(213, 463)
        return true
    }
    adbClick(defaultX, defaultY)
    return false
}

; List → wait WelcomeBackPreClaim → dismiss (137,389) → claim → confirm → ESC to 2nd pack.
; Call from PackOpening "Waiting for Pack".
TryRecoverWelcomeBackMissionsAfterPack(logContext, recoveryPack := "") {
    global session

    if (!IsWelcomeBackMissionsScreen())
        return false

    LogInfo(logContext . ": Welcome Back missions (List) — wait PreClaim, dismiss, claim, ESC", "ADB.txt")
    CreateStatusMessage("Welcome Back missions`nWaiting PreClaim...",,,, false)

    ; Game loads WelcomeBackPreClaim slowly after List
    preClaimStart := A_TickCount
    Loop {
        if (FindOrLoseImage("Mission_WelcomeBackPreClaim", 0, 0, , true))
            break
        if ((A_TickCount - preClaimStart) // 1000 >= 20) {
            LogWarn(logContext . ": WelcomeBackPreClaim not found — continue to claim anyway", "ADB.txt")
            break
        }
        Delay(0.5)
    }

    if (FindOrLoseImage("Mission_WelcomeBackPreClaim", 0, 0, , true)) {
        LogInfo(logContext . ": dismissing WelcomeBackPreClaim", "ADB.txt")
        CreateStatusMessage("Welcome Back missions`nDismissing PreClaim...",,,, false)
        adbClick_wbb(137, 389)
        Delay(1)
    }

    CreateStatusMessage("Welcome Back missions`nClaiming...",,,, false)

    ; Same claim clicks as Daily GetAllRewards(dailies)
    claimStart := A_TickCount
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        Delay(2)
        adbClick(174, 427)
        adbClick(174, 427)
        Delay(1)

        if (FindOrLoseImage("Mission_CompleteGotAllClaims", 0, 0)) {
            LogInfo(logContext . ": Welcome Back claim OK (GotAllMissions)", "ADB.txt")
            break
        }

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        if (failSafeTime > 20) {
            LogWarn(logContext . ": Welcome Back claim timeout without GotAllMissions", "ADB.txt")
            break
        }
    }

    ; List still up — ESC returns to the 2nd pack screen
    LogInfo(logContext . ": Welcome Back claim done — ESC to 2nd pack", "ADB.txt")
    CreateStatusMessage("Welcome Back claimed`nESC to pack...",,,, false)
    adbInputEvent("111")
    Delay(1.5)

    return true
}

waitForAppBootScreen() {
    global session

    if (IsFunc("markRunStartEpochIfPending"))
        markRunStartEpochIfPending(session.get("scriptName"))

    bootTimeoutSec := 90
    session.set("failSafe", A_TickCount)
    CreateStatusMessage("Waiting for app boot screen...",,,, false)
    LogInfo("Boot gate: waiting for startup screen", "ADB.txt")

    lastStatusSec := -1
    Loop {
        if (handleAppHealthDuringSearch("boot", true))
            return false

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        ; Boot only: Welcome / setup / already in main. Welcome Back is handled later while Finding.
        if (FindOrLoseImage("Boot_Welcome", 0, 0, 30, true)) {
            LogInfo("Boot gate: Welcome title screen ready", "ADB.txt")
            return true
        }
        if (FindOrLoseImage("Create_CinematicBackground", 0, , , true)) {
            LogInfo("Boot gate: Cinematic screen ready", "ADB.txt")
            return true
        }
        if (FindOrLoseImage("Create_DownloadComplete", 0, , , true)
            || FindOrLoseImage("Create_DownloadAlertWindow", 0, , , true)
            || FindOrLoseImage("Create_NintendoLink", 0, , , true)) {
            LogInfo("Boot gate: setup/download screen ready", "ADB.txt")
            return true
        }
        if (FindOrLoseImage("Common_ShopButtonInMain", 0, , , true)
            || FindOrLoseImage("Pack_PackPointButton", 0, , , true)
            || FindOrLoseImage("Common_ActivatedHomeInMainMenu", 0, , , true)
            || FindOrLoseImage("Common_ActivatedSocialInMainMenu", 0, , , true)) {
            LogInfo("Boot gate: main screen ready (skipped Welcome)", "ADB.txt")
            return true
        }

        if (failSafeTime != lastStatusSec) {
            lastStatusSec := failSafeTime
            CreateStatusMessage("Waiting for boot screen...`n(" . failSafeTime . "/" . bootTimeoutSec . "s)",,,, false)
        }

        if (failSafeTime >= bootTimeoutSec) {
            LogWarn("Boot gate: timeout after " . bootTimeoutSec . "s", "ADB.txt")
            TriggerGameRestart("Stuck at boot screen...")
            return false
        }

        Sleep, 500
    }
}

getPackCoordXInHome(){
    global botConfig, session

    mapPackX := {"Left":60, "Middle":140, "Right":215}
    packx := mapPackX["Middle"]

    if(botConfig.get("deleteMethod") = "Inject 13p+" || session.get("isReloadAfterAddFriends")){
        session.set("isSkipSelectExpansion", 1)
        if(session.get("openPack") != session.get("mainScreenPackList")["Middle"])
            session.set("isSkipSelectExpansion", 0)
    }
    else if(botConfig.get("deleteMethod") = "Inject Wonderpick 96P+"){
        for index, value in session.get("mainScreenPackList") {
            if (value = session.get("openPack")){
                session.set("isSkipSelectExpansion", 1)
                packx := mapPackX[index]
                break
            }
        }
    }
    return packx
}

startPreProcess(methodType){
    global session, needlesDict

    findImageName := ""
    clickX := 0
    clickY := 0

    if(methodType = "Create Bots (13P)"){
        findImageName := "Country"
        needleName := "Create_CountryComboBoxButton"
        clickX := 143
        clickY := 370
    }
    else if(methodType = "Inject 13p+"){
        findImageName := "Points"
        needleName := "Pack_PackPointButton"
        clickX := getPackCoordXInHome()
        clickY := 203
    }
    else if(methodType = "Inject Wonderpick 96P+"){
        findImageName := "Social"
        needleName := "Common_ActivatedSocialInMainMenu"
        clickX := 143
        clickY := 518
    }
    else if(methodType = "Inject Rewards"){
        findImageName := "Home"
        needleName := "Pack_PackPointButton"
        clickX := getPackCoordXInHome()
        clickY := 203
    }
    else if(methodType = "Rename Account"){
        findImageName := "Home"
        needleName := "Pack_PackPointButton"
        clickX := getPackCoordXInHome()
        clickY := 203
    }

    findImageName .= "`n(Selected pack: " . session.get("openPack") . ")"

    imagePath := A_ScriptDir . "\Needles\"
    searchVariation := 20
    pBitmap := 0
    session.set("isSkipSelectExpansion", 0)
    isSkip := false

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    welcomeBackAdvancing := false
    welcomeBackUseSecondClick := false
    Loop, {
        skipGenericButtonFallback := false

        if (handleAppHealthDuringSearch(findImageName))
            break

        ; Done only when the mode target (Points / Home / Social / Country) is actually visible.
        if(FindOrLoseImage(needleName, 0, failSafeTime, , true))
            break

        if(methodType = "Inject Wonderpick 96P+" && DismissFriendFlowBlockingPopup("Entering Social"))
            continue

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        if (failSafeTime > 90) {
            LogWarn("Entering gate: stuck Finding after 90s — " . findImageName, "ADB.txt")
            if (session.get("injectMethod") && session.get("loadedAccount") && session.get("friended"))
                IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
            restartGameInstance("Stuck at Finding " . findImageName . "...")
        }

        ; After Welcome: Welcome Back may appear while Finding — advance pages until target above returns.
        if (TryAdvanceWelcomeBackWhileFinding("Entering gate", welcomeBackAdvancing, welcomeBackUseSecondClick, failSafeTime))
            continue

        adbClick_wbb(clickX, clickY)
        Delay(0.5)

        if(methodType = "Inject Wonderpick 96P+"){
            if(FindOrLoseImage(needleName, 0, , , true))
                break

            if(FindOrLoseImage("Common_ActivatedHomeInMainMenu", 0, , , true)
                || FindOrLoseImage("Friend_BottomDarkHomeIcon", 0, , , true)
                || FindOrLoseImage("Common_ShopButtonInMain", 0, , , true)
                || FindOrLoseImage("WonderPick_WonderPickButtonInHome", 0, , , true)
                || FindOrLoseImage("Pack_PackPointButton", 0, , , true)
                || FindOrLoseImage("Pack_BackButtonInSelectPackScreen", 0, , , true)
                || FindOrLoseImage("Pack_ReadyForOpenPack", 0, , , true)
                || FindOrLoseImage("Pack_HourglassImageAfterOpenPackClick", 0, , , true)
                || FindOrLoseImage("Pack_HourglassAndPokeGoldImageAfterOpenPackClick", 0, , , true)
                || FindOrLoseImage("Pack_PokeGoldImageAfterOpenPackClick", 0, , , true)){
                skipGenericButtonFallback := true
            }
        }

        pBitmap := from_window(getMuMuHwnd(session.get("winTitle")))

        Path = %imagePath%CrashWhilePackOpen.png
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 20, 180, 35, 182, searchVariation)
        if(vRet = 1){
            CreateStatusMessage("Clearing problem opening pack pop-up",,,, false)
            adbClick_wbb(145, 370)
            Delay(1)
        }
        /*
                Path = %imagePath%HardwareReqs.png
                pNeedle := GetNeedle(Path)
                vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 30, 306, 38, 316, searchVariation)
                if(vRet){
                    CreateStatusMessage("Clearing hardware requirements pop-up",,,, false)
                    adbClick_wbb(199, 370)
                    Delay(1)
                }

                Path = %imagePath%HardwareReq2.png
                pNeedle := GetNeedle(Path)
                vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 41, 388, 92, 403, searchVariation)
                if(vRet){
                    CreateStatusMessage("Clearing hardware requirements pop-up",,,, false)
                    Sleep, 3000
                    adbClick_wbb(199,370)
                    adbClick_wbb(199,370)
                    adbClick_wbb(199,370)
                    Sleep, 2000
                }
        */
        Path = %imagePath%closeduringpack.png
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY
            , needlesDict.Get("Common_AlertForAppCrachDuringOpenPack").coords.startX
            , needlesDict.Get("Common_AlertForAppCrachDuringOpenPack").coords.startY
            , needlesDict.Get("Common_AlertForAppCrachDuringOpenPack").coords.endX
            , needlesDict.Get("Common_AlertForAppCrachDuringOpenPack").coords.endY
            , searchVariation)
        if(vRet = 1){
            CreateStatusMessage("Found closing during pack pop-up",,,, false)
            Delay(1)
            adbClick_wbb(138, 365)
        }

        Path = %imagePath%DataDownload.png
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 41, 378, 92, 393, searchVariation)
        if(vRet = 1){
            CreateStatusMessage("Downloading data",,,, false)
            Sleep, 1000
            adbClick_wbb(198, 375)
            adbClick_wbb(198, 375)
            Sleep, 10000

            ;processPrivacyAgreement()
        }
        processPrivacyAgreement()
        Path = %imagePath%Privacy.png
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 130, 473, 145, 488, searchVariation)
        if(vRet = 1){
            adbClick_wbb(137, 480)
            Sleep, 1000
        }

        Path = %imagePath%LevelUp.png
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 100, 86, 167, 116, searchVariation)
        if(vRet = 1){
            adbInputEvent("111") ;send ESC
            Sleep, 1000
        }

        Path = %imagePath%TradeUnlocked.png
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 114, 146, 163, 197, searchVariation)
        if(vRet = 1){
            adbInputEvent("111") ;send ESC
            Sleep, 1000
        }

        Path = %imagePath%LanguageBox.png
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 8, 374, 30, 398, searchVariation)
        if(vRet = 1){
            adbInputEvent("111") ;send ESC
            Sleep, 1000
        }

        Path = %imagePath%Button.png
        pNeedle := GetNeedle(Path)
        if(!skipGenericButtonFallback){
            vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, 95, 350, 195, 530, 80)
            if(vRet = 1){
                if (InStr(vPosXY, ",")) {
                    StringSplit, pos, vPosXY, `,
                    adbClick_wbb(pos1, pos2)
                } else {
                    adbClick(137, 365)
                }
            }
        }

        DelayH(20)

        Gdip_DisposeImage(pBitmap)

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Entering...(" . failSafeTime "/90 seconds)`nFinding: " . findImageName)
        if (failSafeTime > 90) {
            LogWarn("Entering gate: stuck Finding after 90s — " . findImageName, "ADB.txt")
            if (session.get("injectMethod") && session.get("loadedAccount") && session.get("friended"))
                IniWrite, 1, % session.get("scriptIniFile"), UserSettings, DeadCheck
            restartGameInstance("Stuck at Finding " . findImageName . "...")
        }
    }
}

ReceiveGift(){
    global session, receivedGiftOnly

    if (HasFlagInMetadata(session.get("accountFileName"), "R"))
        return false  ; Not a R flag account

    Loop, {
        if(FindOrLoseImage("Common_ShopButtonInMain", 0)) {
            adbClick_wbb(247, 93)
            Delay(4)
        }

        if(FindOrLoseImage("Gift_ClaimAllButton", 0)) {
            break
        }
    }

    ; Try 5 times
    Loop, 5 {
        adbClick(212, 427)
        Delay(2)
        if (FindOrLoseImage("Gift_ReceivedWindowRightBorder", 0)) {
            adbInputEvent("111") ;send ESC
            Delay(2)
            break
        }
    }
    Delay(1)
    FindImageAndClick("Common_ShopButtonInMain", 138, 505, , 1000)

    receivedGiftOnly := true
}

getDevelopmentScreenShot(packCardType, pBitmap := 0){
    global session

    fileDir := A_ScriptDir "\..\Screenshots\Development"

    if !FileExist(fileDir)
        FileCreateDir, %fileDir%

    ; File path for saving the screenshot locally
    fileName := A_Now . "_" . session.get("scriptName") . "_" . packCardType . ".png"
    filePath := fileDir . "\" . fileName

    if(pBitmap = 0)
        pBitmap := from_window(getMuMuHwnd(session.get("winTitle")))

    Gdip_SaveBitmapToFile(pBitmap, filePath)
}
