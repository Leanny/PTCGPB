; _SendFriendRequest.ahk
; Sends friend request(s) after account inject.
; Prefers InjectAccount.ini [UserSettings] injectFriendRequestIds= (pre-built list for this run).
; Otherwise uses injectSelectedFriendIDs (or legacy injectExtraFriendIDs). At most 10 codes total.
; Usage: _SendFriendRequest.ahk "<winTitle>" "<folderPath>"

#SingleInstance off
SetMouseDelay, -1
SetDefaultMouseSpeed, 0
SetBatchLines, -1
SetTitleMatchMode, 3
CoordMode, Pixel, Screen
#NoEnv

DllCall("AllocConsole")
WinHide % "ahk_id " DllCall("GetConsoleWindow", "ptr")

if (A_Args.Length() < 2) {
    MsgBox, 16, Send Friend Request, Usage:`n`n_SendFriendRequest.ahk "<winTitle>" "<folderPath>"
    ExitApp, 1
}

global g_winTitle   := A_Args[1]
global g_folderPath := A_Args[2]

global g_settingsPath := A_ScriptDir . "\..\Settings.ini"
if (!FileExist(g_settingsPath)) {
    MsgBox, 16, Send Friend Request, Cannot find Settings.ini at:`n%g_settingsPath%
    ExitApp, 1
}

SetWorkingDir, %A_ScriptDir%\..\Scripts

#Include %A_ScriptDir%\..\Scripts\Include\Config.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Session.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Profiler.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Gdip_All.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Gdip_Imagesearch.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Gdip_Extra.ahk

global pToken := Gdip_Startup()

#Include %A_ScriptDir%\..\Scripts\Include\Utils.ahk
#Include %A_ScriptDir%\..\Scripts\Include\MumuHelper.ahk
#Include %A_ScriptDir%\..\Scripts\Include\AccountMetadata.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Database.ahk
#Include %A_ScriptDir%\..\Scripts\Include\AccountManager.ahk
#Include %A_ScriptDir%\..\Scripts\Include\OCR.ahk
#Include %A_ScriptDir%\..\Scripts\Include\ADB.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Coords.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Error.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Crinity_UnofficialPatch.ahk
#Include %A_ScriptDir%\..\Scripts\Include\FriendManager.ahk

global g_injectIniPath := A_ScriptDir . "\InjectAccount.ini"
IniRead, g_injectRequestRaw, %g_injectIniPath%, UserSettings, injectFriendRequestIds,
if (g_injectRequestRaw = "ERROR")
    g_injectRequestRaw := ""
IniRead, g_injectSelectedRaw, %g_injectIniPath%, UserSettings, injectSelectedFriendIDs,
if (g_injectSelectedRaw = "ERROR")
    g_injectSelectedRaw := ""
IniRead, g_injectExtraRaw, %g_injectIniPath%, UserSettings, injectExtraFriendIDs,
if (g_injectExtraRaw = "ERROR")
    g_injectExtraRaw := ""
if (g_injectSelectedRaw = "")
    g_injectSelectedRaw := g_injectExtraRaw

; Logging stubs (avoid pulling in the full Logging.ahk GUI)
global ScriptDir := RegExReplace(A_LineFile, "\\[^\\]+$")
global LogsDir   := A_ScriptDir . "\..\Logs"
global Debug := 0
global discordWebhookURL := ""
global discordUserId := ""
global sendAccountXml := 0
global DeadCheck := 0

CreateStatusMessage(Message, GuiName := "StatusMessage", X := 0, Y := 565, debugOnly := true, Persist := false) {
    global g_mumuHwnd, session
    static statusHwnd := 0
    static statusTextHwnd := 0

    if (Message = "")
        return

    guiWidth := 275
    guiHeight := 30

    try {
        if (!statusHwnd || !DllCall("IsWindow", "Ptr", statusHwnd)) {
            WinGetPos, wx, wy, ww, wh, ahk_id %g_mumuHwnd%
            sx := wx + 4
            sy := wy + wh - 2

            Gui, SendFriendStatus:New, +Owner%g_mumuHwnd% -AlwaysOnTop +ToolWindow -Caption -DPIScale +LastFound
            Gui, SendFriendStatus:Margin, 2, 2
            Gui, SendFriendStatus:Color, 1c1c1c
            Gui, SendFriendStatus:Font, s8 cWhite Norm, Segoe UI
            Gui, SendFriendStatus:Add, Text, hwndstatusTextHwnd w%guiWidth% h%guiHeight% Center, %Message%
            statusHwnd := WinExist()

            DllCall("SetWindowPos", "Ptr", statusHwnd, "Ptr", 1
                , "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)

            Gui, SendFriendStatus:Show, NoActivate x%sx% y%sy% w%guiWidth% h%guiHeight%
        }
        else {
            GuiControl, SendFriendStatus:, %statusTextHwnd%, %Message%
            WinGetPos, wx, wy, ww, wh, ahk_id %g_mumuHwnd%
            sx := wx + 4
            sy := wy + wh - 2
            Gui, SendFriendStatus:Show, NoActivate x%sx% y%sy% w%guiWidth% h%guiHeight%
        }
    } catch e {
    }
}
ResetStatusMessage() {
}
LogToFile(message, logFile := "") {
    global LogsDir
    if (logFile = "")
        logFile := LogsDir . "\Log_" . StrReplace(A_ScriptName, ".ahk") . ".txt"
    else
        logFile := LogsDir . "\" . logFile
    FormatTime, readableTime, %A_Now%, MMMM dd, yyyy HH:mm:ss
    try {
        FileAppend, % "[" readableTime "] " message "`n", %logFile%
    } catch e {
    }
}
LogInfo(message, logFile := "") {
    LogToFile("[info] " . message, logFile)
}
LogWarn(message, logFile := "") {
    LogToFile("[warn] " . message, logFile)
}
LogError(message, logFile := "") {
    LogToFile("[error] " . message, logFile)
}
LogDebug(message, logFile := "") {
    global botConfig
    if (IsObject(botConfig) && (botConfig.get("logLevel") = "debug" || botConfig.get("logLevel") = "trace" || botConfig.get("verboseLogging")))
        LogToFile("[debug] " . message, logFile)
}
LogTrace(message, logFile := "") {
    global botConfig
    if (IsObject(botConfig) && botConfig.get("logLevel") = "trace")
        LogToFile("[trace] " . message, logFile)
}
LogToDiscord(message, screenshotFile := "", ping := false, xmlFile := "", screenshotFile2 := "", altWebhookURL := "", altUserId := "") {
}

;-------------------------------------------------------------------------------
; Stubs for functions that live in 1.ahk
;-------------------------------------------------------------------------------
restartGameInstance(reason, RL := true) {
    LogWarn("restartGameInstance stub: " . reason)
}
Screenshot(filePath := "") {
    return ""
}

global session   := new Session()
global botConfig := new BotConfig()

botConfig.loadSettingsToConfig("ALL")

runtimeFolder := botConfig.get("folderPath")
if (runtimeFolder = "" || !InStr(FileExist(runtimeFolder), "D"))
    botConfig.set("folderPath", g_folderPath, "General")

session.set("scriptName",    g_winTitle)
session.set("winTitle",      g_winTitle)
session.set("scriptIniFile", A_ScriptDir . "\..\Scripts\" . g_winTitle . ".ini")
session.set("dbg_bbox", 0)
session.set("dbg_bboxNpause", 0)
session.set("failSafe", A_TickCount)
session.set("baseTime", 0)
session.set("friended", false)
session.set("setSpeed", 3)
session.set("injectMethod", false)

g_friendIDList := ParseFriendIdsCsv(g_injectRequestRaw)
if (!g_friendIDList.MaxIndex())
    g_friendIDList := ParseFriendIdsCsv(g_injectSelectedRaw)
if (!g_friendIDList.MaxIndex()) {
    MsgBox, 16, Send Friend Request, No friend codes to send.`n`nCheck at least one friend in Inject Account, or set injectFriendRequestIds in InjectAccount.ini.
    ExitApp, 1
}

hwnd := getMuMuHwnd(g_winTitle)
if (!hwnd) {
    MsgBox, 16, Send Friend Request, Cannot find MuMu instance window: %g_winTitle%`n`nMake sure the instance is running.
    ExitWithCleanup(2)
}

global g_mumuHwnd := hwnd

; Position the MuMu window at a fixed location on screen.
CreateStatusMessage("Positioning emulator window...",,,, true)
DirectlyPositionWindow()
Sleep, 500

CreateStatusMessage("Connecting to ADB...",,,, true)
setADBBaseInfo()
ConnectAdb()
initializeAdbShell()

; The adb shell child process opens its own console window; hide it.
try {
    adbPid := session.get("adbShell").ProcessID
    if (adbPid) {
        WinWait, ahk_pid %adbPid%, , 2
        WinHide, ahk_pid %adbPid%
    }
} catch e {
}

;-------------------------------------------------------------------------------
; Main flow
;-------------------------------------------------------------------------------
botConfig.set("deleteMethod", "Inject Wonderpick 96P+")
session.set("injectMethod", true)

; === Step 1: Wait for boot screen ===
waitForAppBootScreen()

; === Step 2: Set speed mod ===
FindImageAndClick("Common_SpeedModMenuButton", 18, 109, , 2000)
if(session.get("setSpeed") = 3)
    FindImageAndClick(GetSpeedModNeedle(3), GetSpeedModClickX(3), GetSpeedModClickY(3))
else
    FindImageAndClick(GetSpeedModNeedle(2), GetSpeedModClickX(2), GetSpeedModClickY(2))
Delay(1)
adbClick_wbb(51, 297)
Delay(1)

; === Step 3: startPreProcess - wait for Social tab ===
startPreProcess("Inject Wonderpick 96P+")

; === Step 4: Send friend requests (AddFriends flow, using InjectAccount.ini IDs) ===
g_friendIdTotal := g_friendIDList.MaxIndex()
CreateStatusMessage("Sending " . g_friendIdTotal . " friend request" . (g_friendIdTotal > 1 ? "s" : "") . "...",,,, true)
result := DoAddFriends(g_friendIDList)

CreateStatusMessage(result ? "All friend requests sent." : "Some requests failed.",,,, true)
Sleep, 1000
ExitWithCleanup(result ? 0 : 4)

;===============================================================================
; DoAddFriends - AddFriends flow using InjectAccount.ini friend IDs
; but takes the friend ID list directly instead of reading ids.txt / Settings.ini.
;===============================================================================
DoAddFriends(friendIDs) {
    global session, interceptProc

    ; === PHASE 1: Wait for Social tab ===
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if (DismissFriendFlowBlockingPopup("Waiting for Social"))
            continue

        if (IsSocialTabActiveOnHub(failSafeTime))
            break

        adbClick_wbb(143, 518)
        if(IsSocialTabActiveOnHub(failSafeTime)) {
            break
        }
        else if(FindOrLoseImage("Common_PopupXButtonInMain", 0, , , true)){
            adbClick_wbb(137, 480)
            Delay(1)
        }
        else if(TryHandleTradeTutorial(failSafeTime))
            continue
        else if(TryDismissSocialFirstTutorial(failSafeTime))
            continue
        else if(FindOrLoseImage("Create_TutorialUseResourceForOpenPack", 0)) {
            Delay(3)
            adbClick_wbb(146, 441)
            Delay(3)
            adbClick_wbb(146, 441)
            Delay(3)
            adbClick_wbb(146, 441)
            Delay(3)

            FindImageAndClick("Create_TutorialPremiumPass", 168, 438, , 500, 5)
            Delay(1)

            adbClick_wbb(203, 436)
        }
        else {
            Delay(3)
            if (!ShouldSkipGenericButtonInSocialWait()) {
                clickButton := FindOrLoseImage("Common_ColorChangeButton", 0, , 80)
                if(clickButton) {
                    StringSplit, pos, clickButton, `,
                    adbClick_wbb(pos1, pos2)
                }
            }
        }

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Social (" . failSafeTime . "/90 seconds)",,,, true)
    }

    ; === PHASE 2: Go to friends list (keep search open) ===
    GoToFriendsList(true, false)

    ; === PHASE 3: Open add-friend-by-ID dialog ===
    FindImageAndClick("Friend_SearchFriendWindowCancelButtonCorner", 75, 440)
    FindFriendIDInputAndClick("", "initial")

    ; === PHASE 4: Send friend requests ===
    n := friendIDs.MaxIndex()
    friendIDIdx := 1
    while(friendIDIdx <= n){
        value := friendIDs[friendIDIdx]

        if (StrLen(value) != 16) {
            friendIDIdx += 1
            continue
        }

        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        skipCurrentID := false
        Loop {
            isContinue := false
            isSendReqeest := false

            if(!SubmitFriendIDSearch(value, friendIDIdx, n)) {
                skipCurrentID := true
                break
            }
            Delay(1)

            if(FindOrLoseImage("Friend_RequestButtonInSearchResult", 0, failSafeTime, 80)) {
                CreateStatusMessage("Sending request " . friendIDIdx . "/" . n . "...",,,, true)
                adbClick_wbb(243, 258)
                MarkFriendCleanupPending("Friend request submitted")
                Delay(1)
                ; --- WaitAfterFriendRequestSend (inlined) ---
                interceptProc := true
                waitSendResult := A_TickCount
                Loop{
                    Delay(0.25)
                    if(interceptErrorCheck("ADD")){
                        isContinue := true
                        break
                    }
                    if(FindOrLoseImage("Friend_WithdrawButton", 0, failSafeTime)) {
                        MarkFriendCleanupPending("Friend request pending")
                        break
                    }
                    else if(FindOrLoseImage("Friend_AcceptedButtonInSearchResult", 0, failSafeTime)) {
                        MarkFriendCleanupPending("Friend accepted")
                        break
                    }
                    else if(FindOrLoseImage("Friend_CannotFriendRequest", 0, failSafeTime)) {
                        LogToFile("Skipping friend ID (cannot friend request) | index=" . friendIDIdx)
                        break
                    }
                    if(!isSendReqeest
                        && (A_TickCount - waitSendResult) > 2500
                        && FindOrLoseImage("Friend_RequestButtonInSearchResult", 0, failSafeTime, 40, true)
                        && !FindOrLoseImage("Friend_WithdrawButton", 0, failSafeTime, , true)
                        && !FindOrLoseImage("Friend_AcceptedButtonInSearchResult", 0, failSafeTime, , true)) {
                        adbClick_wbb(243, 258)
                        MarkFriendCleanupPending("Friend request resubmitted")
                        isSendReqeest := true
                    }
                    if ((A_TickCount - waitSendResult) > 10000)
                        break
                }
                if(interceptErrorCheck("ADD"))
                    isContinue := true
                interceptProc := false
                ; --- end WaitAfterFriendRequestSend ---
                break
            }
            else if(FindOrLoseImage("Friend_WithdrawButton", 0, failSafeTime)) {
                MarkFriendCleanupPending("Friend request pending")
                break
            }
            else if(FindOrLoseImage("Friend_ReqeustButtonInFriendDetails", 0, failSafeTime)) {
                LogToFile("Friend details request button detected | index=" . friendIDIdx)
                adbClick_wbb(143, 407)
                MarkFriendCleanupPending("Friend request submitted from details")
                Delay(1)

                interceptProc := true
                waitSendResult := A_TickCount
                Loop{
                    Delay(0.25)
                    if(FindOrLoseImage("Friend_AcceptedButtonInFriendDetails", 0, failSafeTime)) {
                        MarkFriendCleanupPending("Friend accepted from details")
                        break
                    }
                    else if(interceptErrorCheck("ADD")){
                        skipCurrentID := true
                        LogToFile("Skipping friend ID after ADD error from details | index=" . friendIDIdx)
                        break
                    }
                    else if(FindOrLoseImage("Friend_CannotFriendRequest", 0, failSafeTime)) {
                        LogToFile("Skipping friend ID (cannot request from details) | index=" . friendIDIdx)
                        break
                    }
                    if(!isSendReqeest
                        && (A_TickCount - waitSendResult) > 2500
                        && FindOrLoseImage("Friend_ReqeustButtonInFriendDetails", 0, failSafeTime, , true)
                        && !FindOrLoseImage("Friend_AcceptedButtonInFriendDetails", 0, failSafeTime, , true)) {
                        adbClick_wbb(143, 407)
                        MarkFriendCleanupPending("Friend request resubmitted from details")
                        isSendReqeest := true
                    }
                    if ((A_TickCount - waitSendResult) > 10000)
                        break
                }
                interceptProc := false
                CloseFriendDetailsIfOpen()
                break
            }
            else if(FindOrLoseImage("Friend_AcceptedButtonInFriendDetails", 0, failSafeTime)) {
                MarkFriendCleanupPending("Friend accepted from details")
                CloseFriendDetailsIfOpen()
                break
            }
            else if(FindOrLoseImage("Friend_CannotFriendRequest", 0, failSafeTime)) {
                LogToFile("Skipping friend ID (cannot friend request) | index=" . friendIDIdx)
                break
            }
            else if(interceptErrorCheck("ADD")) {
                isContinue := true
                break
            }
            else if(FindOrLoseImage("Friend_AcceptedButtonInSearchResult", 0, failSafeTime)) {
                MarkFriendCleanupPending("Friend accepted")
                break
            }
            else
                adbInputEvent("59 122 67")

            if (!IsFriendSearchInputReady() && !IsFriendSearchDialogOpen())
                RecoverWrongScreenBeforeFriendIDInput("processing index=" . friendIDIdx)

            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            CreateStatusMessage("Processing add friends (" . failSafeTime . "/45 seconds)",,,, true)
        }

        if(skipCurrentID)
            LogDebug("Skipped friend ID | index=" . friendIDIdx)

        if(isContinue)
            continue

        if(friendIDIdx != n) {
            if(interceptErrorCheck("ADD")) {
                isContinue := true
                continue
            }
            if (!FindFriendIDInputAndClick(1000, "next ID " . (friendIDIdx + 1) . "/" . n))
                break
            EraseInput(friendIDIdx, n)
        }
        friendIDIdx += 1
    }

    ; === PHASE 5: Return to social hub ===
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop, {
        if (IsSocialTabActiveOnHub(failSafeTime))
            break
        adbClick_wbb(143, 518)
        Delay(3)
        if(IsSocialTabActiveOnHub(failSafeTime))
            break
        else if(FindOrLoseImage("Friend_SearchFriendWindowCancelButtonCorner", 0, failSafeTime))
            adbClick_wbb(80, 365)
    }

    return true
}

;===============================================================================
; FindOrLoseImage - local implementation matching 1.ahk's signature.
; Supports needle mode (by name) only; coordinate mode is not used here.
;===============================================================================
FindOrLoseImage(needleName := "DEFAULT", EL := 1, safeTime := 0, searchVariation := 20, notShowFinding := 0, coordImageName := "", coordEL := "", coordSafeTime := "") {
    global needlesDict, g_mumuHwnd, botConfig

    if (coordImageName != "")
        return false

    needleObj := needlesDict.Get(needleName)
    if (!needleObj)
        return false

    ; slowMotion: skip speed mod needles (base game compatibility)
    if(botConfig.get("slowMotion")) {
        if(IsSpeedModImageName(needleObj.imageName))
            return (EL = 0) ? true : false
    }

    pBitmap := from_window(g_mumuHwnd)
    if (!pBitmap)
        return false

    Path := A_ScriptDir . "\..\Scripts\Needles\" . needleObj.imageName . ".png"
    pNeedle := GetNeedle(Path)

    vPosXY := ""
    vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY
        , needleObj.coords.startX, needleObj.coords.startY
        , needleObj.coords.endX,   needleObj.coords.endY
        , searchVariation)
    Gdip_DisposeImage(pBitmap)

    if (EL = 0) {
        if (vRet = 1)
            return vPosXY ? vPosXY : true
        return false
    } else {
        if (vRet != 1)
            return true
        return false
    }
}

;===============================================================================
; FindImageAndClick - local implementation matching 1.ahk's signature.
; Clicks repeatedly until the needle appears, with a 45s timeout.
;===============================================================================
FindImageAndClick(needleName := "DEFAULT", clickx := 0, clicky := 0, searchVariation := 20, sleepTime := "", skip := false, safeTime := 0) {
    global botConfig, g_mumuHwnd, needlesDict

    needleObj := needlesDict.Get(needleName)
    if (!needleObj)
        return false

    ; slowMotion: skip speed mod needles (base game compatibility)
    if(botConfig.get("slowMotion")) {
        if(IsSpeedModImageName(needleObj.imageName))
            return true
    }

    if (sleepTime = "")
        sleepTime := botConfig.get("Delay")

    imagePath := A_ScriptDir . "\..\Scripts\Needles\"
    click := false
    if(clickx > 0 and clicky > 0)
        click := true

    startTime := A_TickCount
    confirmed := false

    if(click) {
        adbClick_wbb(clickx, clicky)
        clickTime := A_TickCount
    }

    Loop {
        Sleep, 100
        if(click) {
            ElapsedClickTime := A_TickCount - clickTime
            if(ElapsedClickTime > sleepTime) {
                adbClick_wbb(clickx, clicky)
                clickTime := A_TickCount
            }
        }

        if (confirmed)
            break

        pBitmap := from_window(g_mumuHwnd)
        Path := imagePath . needleObj.imageName . ".png"
        pNeedle := GetNeedle(Path)
        X1 := needleObj.coords.startX
        Y1 := needleObj.coords.startY
        X2 := needleObj.coords.endX
        Y2 := needleObj.coords.endY
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY, X1, Y1, X2, Y2, searchVariation)
        Gdip_DisposeImage(pBitmap)
        if (vRet = 1) {
            confirmed := vPosXY
        }

        elapsedTime := (A_TickCount - startTime) // 1000
        if (elapsedTime >= 45) {
            LogWarn("FindImageAndClick timed out looking for " . needleName)
            break
        }
    }
    return confirmed
}

;===============================================================================
; GetNeedle - cached bitmap loader
;===============================================================================
GetNeedle(Path) {
    static NeedleBitmaps := Object()

    if (NeedleBitmaps.HasKey(Path))
        return NeedleBitmaps[Path]

    pNeedle := Gdip_CreateBitmapFromFile(Path)
    needleObj := Object()
    needleObj.Path := Path
    pathsplit := StrSplit(Path , "\")
    needleObj.Name := pathsplit[pathsplit.MaxIndex()]
    needleObj.needle := pNeedle
    NeedleBitmaps[Path] := needleObj
    return needleObj
}

;===============================================================================
; ParseFriendIdsCsv / TruncateFriendRequestList
;===============================================================================
ParseFriendIdsCsv(rawCsv) {
    list := []
    cleaned := RegExReplace(rawCsv, "[\r\n]+", ",")
    cleaned := RegExReplace(cleaned, "\|+", ",")
    cleaned := RegExReplace(cleaned, "[\t; ]+", ",")
    Loop {
        if (!InStr(cleaned, ",,"))
            break
        StringReplace, cleaned, cleaned, `,,`,, All
    }
    cleaned := Trim(cleaned, " `t,")
    Loop, Parse, cleaned, `,
    {
        id := Trim(A_LoopField)
        if (!RegExMatch(id, "^\d{16}$"))
            continue
        if (!HasVal(list, id))
            list.Push(id)
    }
    return TruncateFriendRequestList(list)
}

TruncateFriendRequestList(list) {
    if (!IsObject(list) || !list.MaxIndex())
        return list
    if (list.MaxIndex() > 10) {
        oldN := list.MaxIndex()
        fixed := []
        Loop, 10
            fixed.Push(list[A_Index])
        list := fixed
        LogInfo("Friend request list truncated to 10 codes (had " . oldN . ").")
    }
    return list
}

;-------------------------------------------------------------------------------
; DirectlyPositionWindow - position the MuMu window at a fixed location on the
; selected monitor (first grid slot, since trade always uses a single instance).
; Same sequence as 1.ahk: remove title bar, move, restore title bar, redraw,
; then FixInstanceScreen.
;-------------------------------------------------------------------------------
DirectlyPositionWindow() {
    global botConfig, g_winTitle

    scaleParam := 283
    titleHeight := 40 + MuMuBias()
    rowHeight := titleHeight + 492

    SelectedMonitorIndex := RegExReplace(botConfig.get("SelectedMonitorIndex"), ":.*$")
    if (SelectedMonitorIndex = "")
        SelectedMonitorIndex := 1
    SysGet, Monitor, Monitor, %SelectedMonitorIndex%

    ; Trade always uses a single instance - fix it at the first grid slot.
    x := MonitorLeft
    y := MonitorTop

    WinSet, Style, -0xC00000, % "ahk_id " . getMuMuHwnd(g_winTitle)
    WinMove, % "ahk_id " . getMuMuHwnd(g_winTitle), , %x%, %y%, %scaleParam%, %rowHeight%
    WinSet, Style, +0xC00000, % "ahk_id " . getMuMuHwnd(g_winTitle)
    WinSet, Redraw, , % "ahk_id " . getMuMuHwnd(g_winTitle)

    FixInstanceScreen(g_winTitle)
}

;-------------------------------------------------------------------------------
; Gdip_ImageSearch_wbb - wrapper around Gdip_ImageSearch that applies MuMuBias
; to Y coordinates.
;-------------------------------------------------------------------------------
Gdip_ImageSearch_wbb(pBitmapHaystack, pNeedle, ByRef OutputList=""
    , OuterX1=0, OuterY1=0, OuterX2=0, OuterY2=0, Variation=0, Trans=""
    , SearchDirection=1, Instances=1, LineDelim="`n", CoordDelim=",") {
    global session

    bias := MuMuBias()

    vret := Gdip_ImageSearch(pBitmapHaystack, pNeedle.needle, OutputList
        , OuterX1, OuterY1+bias, OuterX2, OuterY2+bias, Variation, Trans
        , SearchDirection, Instances, LineDelim, CoordDelim)
    return vret
}

;-------------------------------------------------------------------------------
; adbClick_wbb - adbClick with optional bounding-box debug overlay.
;-------------------------------------------------------------------------------
adbClick_wbb(X, Y) {
    global session
    if (session.get("dbg_bbox"))
        bboxAndPause_click(X, Y, session.get("dbg_bboxNpause"))
    adbClick(X, Y)
}

bboxAndPause_click(X, Y, doPause := false) {
    global session
    guiSuffix := session.get("winTitle")
    color := "BackgroundBlue"
    bboxDraw(X-5, Y-5, X+5, Y+5, color, guiSuffix)
    if (doPause)
        Pause
    Gui, BoundingBox%guiSuffix%:Destroy
}

bboxDraw(X1, Y1, X2, Y2, color, guiSuffix := "") {
    global g_mumuHwnd
    WinGetPos, wx, wy, , , ahk_id %g_mumuHwnd%
    X1 += wx
    Y1 += wy
    X2 += wx
    Y2 += wy
    Gui, BoundingBox%guiSuffix%:New, +AlwaysOnTop -Caption +ToolWindow -DPIScale
    Gui, BoundingBox%guiSuffix%:Color, %color%
    Gui, BoundingBox%guiSuffix%:Show, x%X1% y%Y1% w%X2% h%Y2% NoActivate
}

ExitWithCleanup(code := 0) {
    global pToken, session
    Gui, SendFriendStatus:Destroy
    try {
        if (session.get("adbShell"))
            session.get("adbShell").Terminate()
    } catch e {
    }
    try {
        Gdip_Shutdown(pToken)
    } catch e {
    }
    ExitApp, % code
}

OnGuiClose:
GuiClose:
    ExitWithCleanup(0)
return
