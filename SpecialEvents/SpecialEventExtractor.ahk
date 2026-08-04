#NoEnv
#SingleInstance Force
SetBatchLines, -1
SetTitleMatchMode, 3
CoordMode, Mouse, Client

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
Gui, Add, Text, x10 y+15 w170, Claim Steps (Days):
Gui, Add, Edit, vInputClaimSteps w100 x+10 yp-5, 1
Gui, Add, Text, x10 y+15 w170, Claim Days (opt, e.g. 3,5):
Gui, Add, Edit, vInputClaimDays w100 x+10 yp-5,
Gui, Add, Text, x10 y+15 w170, Gift Days (opt, e.g. 2,4):
Gui, Add, Edit, vInputGiftDays w100 x+10 yp-5,

Gui, Add, Button, gBtnSave x50 y+20 w100, Save
Gui, Add, Button, gBtnClose x+10 yp w100, Close

OnMessage(0x201, "WM_LBUTTONDOWN")
OnMessage(0x202, "WM_LBUTTONUP")
OnMessage(0x204, "WM_RBUTTONDOWN")
OnMessage(0x205, "WM_RBUTTONUP")
OnMessage(0x200, "WM_MOUSEMOVE")

Gui, Show,, Special Event Extractor Tool

LoadInstanceList()
GoSub, BtnRefresh
return

OnAppPlayerChange:
BtnRefresh:
    Gui, Submit, NoHide

    if (pBgBitmap)
        Gdip_DisposeImage(pBgBitmap)
    if (pScaledBgBitmap)
        Gdip_DisposeImage(pScaledBgBitmap)

    GuiControlGet, curInstance,, instanceList

    winTitleWithClass := curInstance . " ahk_class Qt5156QWindowIcon"
    scaleParam := "283"
    titleHeight := 40
    rowHeight := titleHeight + 492

    WinMove, %winTitleWithClass%, , , , %scaleParam%, %rowHeight%

    pBgBitmap := from_window(curInstance)

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

    ConfirmMsg := "Are you sure you want to save the following details?`n`n"
        . "Event Name: " . InputName . "`n"
        . "Expires in: " . InputExpiresInDays . " day(s)`n"
        . "Calculated End (UTC): " . displayExpDate . " " . InputExpTime . "`n"
        . "Claim Steps (Days): " . InputClaimSteps . "`n"
        . "Claim Days: " . claimDaysDisplay . "`n"
        . "Gift Days: " . giftDaysDisplay . "`n"
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
    GuiControlGet, mumuBaseFolder,, MyText

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
