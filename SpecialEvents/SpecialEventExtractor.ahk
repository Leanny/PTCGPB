#NoEnv
#SingleInstance Force
SetBatchLines, -1
SetTitleMatchMode, 3
CoordMode, Mouse, Screen

#Include %A_ScriptDir%\..\Scripts\Include\Gdip_ALL.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Profiler.ahk
#Include %A_ScriptDir%\..\Scripts\Include\Utils.ahk

If !pToken := Gdip_Startup()
{
    MsgBox, 48, Gdiplus Error, Could not load GDI+ library. Please check Gdip_All.ahk.
    ExitApp
}

global pBgBitmap := 0
global pDisplayBitmap := 0
global LastMouseX := -1
global LastMouseY := -1

global pBgBitmap := 0
global pDisplayBitmap := 0
global hScreenPic
global PicWidth := 275
global PicHeight := 528

global RedBox := {x1: 0, y1: 0, x2: 0, y2: 0, drawing: 0, exists: 0}
global BlueBox := {x1: 0, y1: 0, x2: 0, y2: 0, drawing: 0, exists: 0}

Gui, +HwndhGui
Gui, Margin, 10, 10

Gui, Add, DropDownList, vinstanceList x10 w200 gOnAppPlayerChange,
Gui, Add, Button, gBtnRefresh x+10 w80 yp-2, Refresh

Gui, Add, Picture, hwndhScreenPic vScreenCtrl w%PicWidth% h%PicHeight% x15 y+10 +0x0100 +Border +0xE

Gui, Add, Text, x10 y+15 w170, Name:
Gui, Add, Edit, vInputName w100 x+10 yp-5
Gui, Add, Text, x10 y+15 w170, Expires in (days):
Gui, Add, Edit, vInputExpiresInDays w100 x+10 yp-5
Gui, Add, Text, x10 y+15 w170, Expiry Time(UTC,hh:mm:ss):
Gui, Add, Edit, vInputExpTime w100 x+10 yp-5, 05:59:59
Gui, Add, Text, vLblClaimSteps +0x100 x10 y+15 w170, Claim Steps:
Gui, Add, Edit, vInputClaimSteps w100 x+10 yp-5, 1
Gui, Add, Checkbox, vInputEliteDeck x10 y+15 w270, Elite Deck event

Gui, Add, Text, x10 y+20 w270 cBlue, Optional fields:
Gui, Add, Text, vLblClaimDays +0x100 x10 y+10 w170, Claim Days:
Gui, Add, Edit, vInputClaimDays w100 x+10 yp-5,
Gui, Add, Text, vLblGiftDays +0x100 x10 y+10 w170, Gift Days:
Gui, Add, Edit, vInputGiftDays w100 x+10 yp-5,

Gui, Add, Button, gBtnSave x50 y+20 w100, Save
Gui, Add, Button, gBtnClose x+10 yp w100, Close

OnMessage(0x201, "WM_LBUTTONDOWN")
OnMessage(0x202, "WM_LBUTTONUP")
OnMessage(0x204, "WM_RBUTTONDOWN")
OnMessage(0x205, "WM_RBUTTONUP")
OnMessage(0x200, "HelpTT_OnMouseMove")
OnMessage(0x201, "HelpTT_OnLButtonDown")

Gui, Show,, Special Event Extractor Tool

global g_HelpTT := {}
global g_HelpTT_Last := ""
global g_HelpTT_Visible := 0
g_HelpTT["LblClaimSteps"] := "Total number of days this event can be claimed.`nThe bot claims once per game day, up to this number.`nWhen the bot has claimed this many times, the event is marked as complete.`nExample: 7 means the bot will claim once per day for 7 days."
g_HelpTT["LblClaimDays"] := "Which specific day numbers should trigger the in-game claim screen.`nBy default (empty), the bot claims on every step.`nUse comma-separated numbers to claim only on specific days.`nExample: 3,5 means the bot opens the claim screen only on day 3 and day 5.`nOther days are still counted but skipped in-game."
g_HelpTT["LblGiftDays"] := "Which specific day numbers should force the bot to open received gifts.`nBy default (empty), the bot never opens gifts for this event.`nUse comma-separated numbers to force gift opening on specific days.`nExample: 2,4 means the bot opens gifts on day 2 and day 4."

LoadInstanceList()
GoSub, BtnRefresh
return

OnAppPlayerChange:
BtnRefresh:
    Gui, Submit, NoHide

    if (pBgBitmap)
        Gdip_DisposeImage(pBgBitmap)

    GuiControlGet, curInstance,, instanceList

    winTitleWithClass := curInstance . " ahk_class Qt5156QWindowIcon"
    scaleParam := "283"
    titleHeight := 40
    rowHeight := titleHeight + 492

    WinMove, %winTitleWithClass%, , , , %scaleParam%, %rowHeight%

    pBgBitmap := from_window(winTitleWithClass)

    RedBox.exists := 0
    BlueBox.exists := 0
    UpdateDisplay()
return

BtnSave:
    Gui, Submit, NoHide

    if (!InputName) {
        MsgBox, 48, Notice, Please enter a Name.
        return
    }

    if (InputExpiresInDays = "" || !RegExMatch(InputExpiresInDays, "^\d+$") || (InputExpiresInDays + 0) < 1) {
        MsgBox, 48, Format Error, Expires in (days) must be an integer >= 1.`nUse the in-game countdown (e.g. 8 if it says expires in 8 days).
        return
    }

    if !RegExMatch(InputExpTime, "^\d{2}:\d{2}:\d{2}$") {
        MsgBox, 48, Format Error, Invalid Expiry Time format. (hh:mm:ss)`nExample: 05:59:59
        return
    }

    if (InputClaimSteps = "" || !RegExMatch(InputClaimSteps, "^\d+$") || (InputClaimSteps + 0) < 1) {
        MsgBox, 48, Format Error, Claim Steps (Days) must be an integer >= 1.`nExample: 7 for a 7-day login event`nUse 1 for a one-shot claim.
        return
    }
    if (InputClaimDays != "" && !RegExMatch(InputClaimDays, "^(\d+)(\s*,\s*\d+)*$")) {
        MsgBox, 48, Format Error, Claim Days must be empty or a comma-separated list of integers.`nExample: 3,5`nLeave empty to claim every step.
        return
    }
    if (InputGiftDays != "" && !RegExMatch(InputGiftDays, "^(\d+)(\s*,\s*\d+)*$")) {
        MsgBox, 48, Format Error, Gift Days must be empty or a comma-separated list of integers.`nExample: 2,4`nLeave empty for no forced gift days.
        return
    }
    if (!RedBox.exists || !BlueBox.exists) {
        MsgBox, 48, Notice, Please draw both Red and Blue boxes.
        return
    }

    convExpTime := StrReplace(InputExpTime, ":")
    convExpDate := CalcExpiryDateFromRemainingDays(InputExpiresInDays + 0, convExpTime)
    displayExpDate := SubStr(convExpDate, 1, 4) . "-" . SubStr(convExpDate, 5, 2) . "-" . SubStr(convExpDate, 7, 2)
    claimDaysDisplay := (InputClaimDays = "") ? "(all steps)" : InputClaimDays
    giftDaysDisplay := (InputGiftDays = "") ? "(none)" : InputGiftDays
    eliteDeckDisplay := InputEliteDeck ? "Yes" : "No"

    ConfirmMsg := "Are you sure you want to save the following details?`n`n"
        . "Event Name: " . InputName . "`n"
        . "Expires in: " . InputExpiresInDays . " day(s)`n"
        . "Calculated End (UTC): " . displayExpDate . " " . InputExpTime . "`n"
        . "Claim Steps (Days): " . InputClaimSteps . "`n"
        . "Claim Days: " . claimDaysDisplay . "`n"
        . "Gift Days: " . giftDaysDisplay . "`n"
        . "Elite Deck: " . eliteDeckDisplay . "`n"
        . "Box Coordinates: Set"

    MsgBox, 4, Final Confirmation, %ConfirmMsg%
    IfMsgBox, No
        return

    EventFolder := A_ScriptDir . "\Events"
    if !FileExist(EventFolder)
        FileCreateDir, %EventFolder%

    rx1 := Min(RedBox.x1, RedBox.x2), ry1 := Min(RedBox.y1, RedBox.y2)
    rx2 := Max(RedBox.x1, RedBox.x2), ry2 := Max(RedBox.y1, RedBox.y2)
    rw := rx2 - rx1, rh := ry2 - ry1
    pCroppedRed := Gdip_CloneBitmapArea(pBgBitmap, rx1, ry1, rw, rh)
    RedBase64 := BitmapToBase64(pCroppedRed)
    Gdip_DisposeImage(pCroppedRed)

    bx1 := Min(BlueBox.x1, BlueBox.x2), by1 := Min(BlueBox.y1, BlueBox.y2)
    bx2 := Max(BlueBox.x1, BlueBox.x2), by2 := Max(BlueBox.y1, BlueBox.y2)
    bw := bx2 - bx1, bh := by2 - by1
    pCroppedBlue := Gdip_CloneBitmapArea(pBgBitmap, bx1, by1, bw, bh)
    BlueBase64 := BitmapToBase64(pCroppedBlue)
    Gdip_DisposeImage(pCroppedBlue)

    SaveContent =
    (LTrim
        [TargetInfo]
        EventName=%InputName%
        ExpiryDate=%convExpDate%
        ExpiryTime=%convExpTime%
        ClaimSteps=%InputClaimSteps%
        ClaimDays=%InputClaimDays%
        GiftDays=%InputGiftDays%
        EliteDeck=%InputEliteDeck%

        [RedBox]
        Coords=%rx1%, %ry1%, %rx2%, %ry2%
        ImageData=%RedBase64%

        [BlueBox]
        Coords=%bx1%, %by1%, %bx2%, %by2%
        ImageData=%BlueBase64%
    )

    FileName := EventFolder . "\" . InputName . ".sevt"
    FileDelete, %FileName%
    FileAppend, %SaveContent%, %FileName%

    MsgBox, 64, Success, The file %InputName%.sevt has been successfully saved in the Events folder.`nEnd (UTC): %displayExpDate% %InputExpTime%
return

BtnClose:
GuiClose:
    if (pBgBitmap)
        Gdip_DisposeImage(pBgBitmap)
    if (pDisplayBitmap)
        Gdip_DisposeImage(pDisplayBitmap)
    Gdip_Shutdown(pToken)
ExitApp

; Convert in-game "expires in N days" + UTC cutoff time into ExpiryDate (YYYYMMDD).
; Uses the next UTC ExpiryTime as day 0 boundary, then adds remainingDays.
CalcExpiryDateFromRemainingDays(remainingDays, expiryTimeCompact := "055959") {
    if (remainingDays = "" || (remainingDays + 0) < 1)
        remainingDays := 1
    if (expiryTimeCompact = "")
        expiryTimeCompact := "055959"

    utcNow := A_NowUTC
    utcDate := SubStr(utcNow, 1, 8)
    utcTime := SubStr(utcNow, 9, 6)
    nextCutoffDate := utcDate
    if (utcTime >= expiryTimeCompact)
        nextCutoffDate += 1, Days

    endDate := nextCutoffDate
    endDate += remainingDays, Days
    return SubStr(endDate, 1, 8)
}

ResolveMuMuFolder(){
    mumuFolder := getMuMuFolderInConfig()
    if (!IsNumeric(mumuFolder))
        return mumuFolder

    settingsPath := A_ScriptDir . "\..\ Settings.ini"
    IniRead, configuredFolder, %settingsPath%, UserSettings, folderPath, C:\Program Files\Netease
    configuredFolder := Trim(configuredFolder)

    resolvedFolder := TryResolveMuMuFolder(configuredFolder)
    if (resolvedFolder != "")
        return resolvedFolder

    MsgBox, 16, , Can't Find MuMu, try old MuMu installer in Discord #announcements, otherwise double check your folder path setting!`nDefault path is C:\Program Files\Netease
    return ""
}

TryResolveMuMuFolder(baseFolder){
    subFolderList := ["MuMuPlayerGlobal-12.0", "MuMu Player 12", "MuMuPlayer-12.0", "MuMuPlayer", "MuMuPlayer-12", "MuMuPlayer12"]

    if (!InStr(FileExist(baseFolder), "D"))
        return ""

    if (InStr(FileExist(baseFolder . "\vms"), "D") || InStr(FileExist(baseFolder . "\shell"), "D"))
        return baseFolder

    For idx, value in subFolderList {
        mumuFolder := baseFolder . "\" . value
        if (InStr(FileExist(mumuFolder), "D"))
            return mumuFolder
    }

    return ""
}

LoadInstanceList(){
    instanceListStr := ""
    mumuBaseFolder := ""

    mumuFolder := ResolveMuMuFolder()
    if (mumuFolder = "") {
        GuiControl,, instanceList, |
        return
    }
    ; Loop through all VM directories
    Loop, Files, %mumuFolder%\vms\*, D
    {
        folder := A_LoopFileFullPath
        configFolder := folder "\configs"

        if InStr(FileExist(configFolder), "D") {
            extraConfigFile := configFolder "\extra_config.json"

            if FileExist(extraConfigFile) {
                FileRead, fileContent, %extraConfigFile%
                RegExMatch(fileContent, """playerName"":\s*""(.*?)""", playerName)
                if (playerName1 != "") {
                    if (instanceListStr != "")
                        instanceListStr .= "|"
                    instanceListStr .= playerName1
                }
            }
        }
    }

    GuiControl,, instanceList, |%instanceListStr%
}

WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global hScreenPic, RedBox
    if (hwnd = hScreenPic) {
        GetMousePosInCtrl(hScreenPic, x, y)
        RedBox.x1 := x, RedBox.y1 := y
        RedBox.x2 := x, RedBox.y2 := y
        RedBox.drawing := 1
        RedBox.exists := 0
    }
}

WM_LBUTTONUP(wParam, lParam, msg, hwnd) {
    global RedBox
    if (RedBox.drawing) {
        RedBox.drawing := 0
        if (Abs(RedBox.x1 - RedBox.x2) > 5 && Abs(RedBox.y1 - RedBox.y2) > 5)
            RedBox.exists := 1
        UpdateDisplay()
    }
}

WM_RBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global hScreenPic, BlueBox
    if (hwnd = hScreenPic) {
        GetMousePosInCtrl(hScreenPic, x, y)
        BlueBox.x1 := x, BlueBox.y1 := y
        BlueBox.x2 := x, BlueBox.y2 := y
        BlueBox.drawing := 1
        BlueBox.exists := 0
    }
}

WM_RBUTTONUP(wParam, lParam, msg, hwnd) {
    global BlueBox
    if (BlueBox.drawing) {
        BlueBox.drawing := 0
        if (Abs(BlueBox.x1 - BlueBox.x2) > 5 && Abs(BlueBox.y1 - BlueBox.y2) > 5)
            BlueBox.exists := 1
        UpdateDisplay()
    }
}

WM_MOUSEMOVE(wParam, lParam, msg, hwnd) {
    global hScreenPic, RedBox, BlueBox, LastMouseX, LastMouseY
    if (hwnd = hScreenPic) {
        if (RedBox.drawing || BlueBox.drawing) {
            GetMousePosInCtrl(hScreenPic, x, y)

            if (x == LastMouseX && y == LastMouseY)
                return

            LastMouseX := x, LastMouseY := y

            if (RedBox.drawing)
                RedBox.x2 := x, RedBox.y2 := y
            if (BlueBox.drawing)
                BlueBox.x2 := x, BlueBox.y2 := y
            UpdateDisplay()
        }
    }
}

HelpTT_OnMouseMove(wParam, lParam, msg, hwnd) {
    global g_HelpTT, g_HelpTT_Last, g_HelpTT_Visible
    ctrl := A_GuiControl
    if (ctrl = g_HelpTT_Last)
        return
    g_HelpTT_Last := ctrl
    if (g_HelpTT_Visible)
        HelpTT_HideWindow()
    SetTimer, HelpTT_Hide, Off
    if (ctrl != "" && g_HelpTT.HasKey(ctrl))
        SetTimer, HelpTT_Show, -500
    else
        SetTimer, HelpTT_Show, Off
}

HelpTT_OnLButtonDown(wParam, lParam, msg, hwnd) {
    HelpTT_DismissForClick()
}

HelpTT_Dismiss() {
    global g_HelpTT_Last
    SetTimer, HelpTT_Show, Off
    SetTimer, HelpTT_Hide, Off
    HelpTT_HideWindow()
    g_HelpTT_Last := ""
}

HelpTT_DismissForClick() {
    global g_HelpTT_Last
    clickedCtrl := A_GuiControl
    HelpTT_Dismiss()
    g_HelpTT_Last := clickedCtrl
}

HelpTT_Show:
    if (g_HelpTT_Last != "" && g_HelpTT.HasKey(g_HelpTT_Last)) {
        HelpTT_ShowWindow(g_HelpTT[g_HelpTT_Last])
        SetTimer, HelpTT_Hide, -15000
    }
return

HelpTT_Hide:
    HelpTT_HideWindow()
return

HelpTT_ShowWindow(text) {
    global g_HelpTT_Visible

    hHelpTTWin := 0
    widthOpt := ""
    Loop, 2 {
        Gui, HelpTTWin:Destroy
        Gui, HelpTTWin:New, +AlwaysOnTop -Caption +ToolWindow +Border +HwndhHelpTTWin +E0x08000020
        Gui, HelpTTWin:Margin, 12, 9
        Gui, HelpTTWin:Color, 23272E
        Gui, HelpTTWin:Font, s9 cD8DEE9, Segoe UI
        Gui, HelpTTWin:Add, Text, BackgroundTrans %widthOpt%, %text%
        Gui, HelpTTWin:Show, Hide
        WinGetPos,,, ttW, ttH, ahk_id %hHelpTTWin%
        if (ttW <= 540 || widthOpt != "")
            break
        widthOpt := "w520"
    }

    MouseGetPos, mx, my
    SysGet, monCount, MonitorCount
    waLeft := 0, waTop := 0, waRight := A_ScreenWidth, waBottom := A_ScreenHeight
    Loop, %monCount% {
        SysGet, wa, MonitorWorkArea, %A_Index%
        if (mx >= waLeft && mx <= waRight && my >= waTop && my <= waBottom)
            break
    }
    x := mx + 14
    y := my + 20
    if (x + ttW > waRight)
        x := waRight - ttW - 6
    if (y + ttH > waBottom)
        y := my - ttH - 12
    if (x < waLeft)
        x := waLeft + 6
    if (y < waTop)
        y := waTop + 6

    cornerPref := 3
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hHelpTTWin, "UInt", 33, "Int*", cornerPref, "UInt", 4)

    Gui, HelpTTWin:Show, x%x% y%y% NA
    WinSet, Transparent, 245, ahk_id %hHelpTTWin%
    g_HelpTT_Visible := 1
}

HelpTT_HideWindow() {
    global g_HelpTT_Visible
    Gui, HelpTTWin:Destroy
    g_HelpTT_Visible := 0
}

GetMousePosInCtrl(hwnd, ByRef x, ByRef y) {
    VarSetCapacity(pt, 8)
    DllCall("GetCursorPos", "Ptr", &pt)
    DllCall("ScreenToClient", "Ptr", hwnd, "Ptr", &pt)
    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")
}

UpdateDisplay() {
    global pBgBitmap, hScreenPic, PicWidth, PicHeight
    global RedBox, BlueBox

    if (!pBgBitmap || pBgBitmap <= 0)
        return

    pDisplayBitmap := Gdip_CreateBitmap(PicWidth, PicHeight)
    pGraphics := Gdip_GraphicsFromImage(pDisplayBitmap)

    Gdip_DrawImage(pGraphics, pBgBitmap, 0, 0, PicWidth, PicHeight, 0, 0, PicWidth, PicHeight)

    if (RedBox.exists || RedBox.drawing) {
        pPenRed := Gdip_CreatePen(0xFFFF0000, 2)
        x := Min(RedBox.x1, RedBox.x2), y := Min(RedBox.y1, RedBox.y2)
        w := Abs(RedBox.x1 - RedBox.x2), h := Abs(RedBox.y1 - RedBox.y2)
        Gdip_DrawRectangle(pGraphics, pPenRed, x, y, w, h)
        Gdip_DeletePen(pPenRed)
    }

    if (BlueBox.exists || BlueBox.drawing) {
        pPenBlue := Gdip_CreatePen(0xFF0000FF, 2)
        x := Min(BlueBox.x1, BlueBox.x2), y := Min(BlueBox.y1, BlueBox.y2)
        w := Abs(BlueBox.x1 - BlueBox.x2), h := Abs(BlueBox.y1 - BlueBox.y2)
        Gdip_DrawRectangle(pGraphics, pPenBlue, x, y, w, h)
        Gdip_DeletePen(pPenBlue)
    }

    hBitmap := Gdip_CreateHBITMAPFromBitmap(pDisplayBitmap)

    Gdip_DeleteGraphics(pGraphics)
    Gdip_DisposeImage(pDisplayBitmap)

    SendMessage, 0x172, 0x0, %hBitmap%, , ahk_id %hScreenPic%
    if (ErrorLevel)
        DeleteObject(ErrorLevel)
}

Max(a, b) {
    return (a > b) ? a : b
}

Min(a, b) {
    return (a < b) ? a : b
}

BitmapToBase64(pBitmap) {
    DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", true, "ptr*", pStream)

    DllCall("gdiplus\GdipGetImageEncodersSize", "uint*", nCount, "uint*", nSize)
    VarSetCapacity(ci, nSize)
    DllCall("gdiplus\GdipGetImageEncoders", "uint", nCount, "uint", nSize, "ptr", &ci)

    cb := (A_PtrSize = 8) ? 104 : 76
    offset := (A_PtrSize = 8) ? 64 : 48

    pCodec := 0
    Loop, % nCount {
        pCurrentCodec := &ci + (A_Index - 1) * cb

        pMimeType := NumGet(pCurrentCodec + 0, offset, "ptr")
        sString := StrGet(pMimeType, "UTF-16")

        if (sString = "image/png") {
            pCodec := pCurrentCodec
            break
        }
    }

    if (!pCodec) {
        ObjRelease(pStream)
        MsgBox, 16, Error, Could not find PNG encoder.
        return ""
    }

    DllCall("gdiplus\GdipSaveImageToStream", "ptr", pBitmap, "ptr", pStream, "ptr", pCodec, "uint", 0)

    DllCall("ole32\GetHGlobalFromStream", "ptr", pStream, "uint*", hData)
    pData := DllCall("GlobalLock", "ptr", hData)
    nSize := DllCall("GlobalSize", "uint", pData)

    DllCall("Crypt32.dll\CryptBinaryToString", "ptr", pData, "uint", nSize, "uint", 0x01, "ptr", 0, "uint*", nReq)
    VarSetCapacity(sBase64, nReq * (A_IsUnicode ? 2 : 1), 0)
    DllCall("Crypt32.dll\CryptBinaryToString", "ptr", pData, "uint", nSize, "uint", 0x01, "str", sBase64, "uint*", nReq)

    DllCall("GlobalUnlock", "ptr", hData)
    ObjRelease(pStream)

    sBase64 := RegExReplace(sBase64, "\s+", "")
    return sBase64
}
