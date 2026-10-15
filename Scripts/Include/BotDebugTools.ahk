; Screenshots and swipe debugging helpers

SaveStuckScreenshot(reason) {
    prof := Prof_Scope(A_ThisFunc)
    global session

    fileDir := A_ScriptDir . "\..\Screenshots\Stuck"
    if !FileExist(fileDir)
        FileCreateDir, %fileDir%

    safeReason := RegExReplace(reason, "[\\/:*?""<>|]", "_")
    safeReason := RegExReplace(safeReason, "\s+", "_")
    safeReason := SubStr(safeReason, 1, 80)

    deviceAccount := GetCurrentDeviceAccountForMetadata()
    if (deviceAccount = "")
        deviceAccount := "unknown_device_account"
    safeDeviceAccount := RegExReplace(deviceAccount, "[\\/:*?""<>|]", "_")
    safeDeviceAccount := RegExReplace(safeDeviceAccount, "\s+", "_")
    safeDeviceAccount := SubStr(safeDeviceAccount, 1, 80)

    filePath := fileDir . "\" . A_Now . "_inst" . session.get("scriptName") . "_" . safeDeviceAccount . "_" . safeReason . ".png"

    hWnd := getMuMuHwnd(session.get("winTitle"))
    if (!hWnd)
        return

    pBitmap := from_window(hWnd)
    if (pBitmap) {
        Gdip_SaveBitmapToFile(pBitmap, filePath)
        Gdip_DisposeImage(pBitmap)
        LogInfo("Saved stuck screenshot: " . filePath)
    }
}

Screenshot_dev(fileType := "Dev", subDir := "", srcPath := "") {
    prof := Prof_Scope(A_ThisFunc)
    global session, rec_Active
    SetWorkingDir %A_ScriptDir%  ; Ensures the working directory is the script's directory

    ; Define folder and file paths
    fileDir := A_ScriptDir "\..\Screenshots\grab"
    if !FileExist(fileDir)
        FileCreateDir, %fileDir%
    if (subDir) {
        fileDir .= "\" . subDir
    }
    if !FileExist(fileDir)
        FileCreateDir, %fileDir%

    ; File path for saving the screenshot locally
    fileName := A_Now . "_" . session.get("scriptName") . "_" . fileType . ".png"
    filePath := fileDir "\" . fileName

    if (srcPath != "" && FileExist(srcPath))
        pBitmapW := Gdip_CreateBitmapFromFile(srcPath)
    else
        pBitmapW := from_window(getMuMuHwnd(session.get("winTitle")))
    Gdip_SaveBitmapToFile(pBitmapW, filePath)

    sleep 100

    try {
        CoordMode, Mouse, Client
        OwnerWND := WinExist(session.get("winTitle"))
        buttonWidth := 40

        guiSuffix := session.get("winTitle")
        Gui, DevMode_ss%guiSuffix%:New, +LastFound -DPIScale
        Gui, DevMode_ss%guiSuffix%:Add, Picture, x0 y0 w275 h528 hwndhAppScreen, %filePath%
        Gui, DevMode_ss%guiSuffix%:Show, w275 h528, % "Screensho" session.get("winTitle")

        GuiControlGet, PicPos, Pos, %hAppScreen%

        sleep 100
        msgbox click on top-left corner and bottom-right corners

        yBias := 40

        KeyWait, LButton, D
        MouseGetPos , X1, Y1, OutputVarWin, OutputVarControl
        KeyWait, LButton, U
        X1 := X1 - PicPosX
        Y1 := Y1 - PicPosY

        ; Return in case of user close the screen
        if !WinExist("Screensho" session.get("winTitle"))
            return

        KeyWait, LButton, D
        MouseGetPos , X2, Y2, OutputVarWin, OutputVarControl
        KeyWait, LButton, U
        X2 := X2 - PicPosX
        Y2 := Y2 - PicPosY

        W:=X2-X1
        H:=Y2-Y1

        MsgBox, % X1 ", " Y1 " / " X2 ", " Y2

        pBitmap := Gdip_CloneBitmapArea(pBitmapW, X1, Y1, W, H)

        InputBox, fileName, ,"Enter the name of the needle to save"

        if (fileName = "") {
            return ""
        }

        fullScreenPath := filePath
        fileDir := A_ScriptDir . "\Needles"
        filePath := fileDir "\" . fileName . ".png"
        Gdip_SaveBitmapToFile(pBitmap, filePath)

        KeyWait, LButton, D
        MouseGetPos , X3, Y3, OutputVarWin, OutputVarControl
        KeyWait, LButton, U
        X3 := X3 - PicPosX
        Y3 := Y3 - PicPosY

        global rec_LastScreenGrab
        rec_LastScreenGrab := {fileName: fileName, needlePath: filePath
            , screenshot: fullScreenPath
            , x1: X1, y1: Y1, x2: X2, y2: Y2, x3: X3, y3: Y3}

        ; Convert window coordinates to device/OCR coordinates
        ; Device resolution: 540x960, Window resolution: 277x489, Y offset: 44
        OCR_X1 := Round(X1 * 540 / 283)
        OCR_Y1 := Round((Y1 - 44) * 960 / 488)
        OCR_W := Round(W * 540 / 283)
        OCR_H := Round(H * 960 / 488)
        OCR_X2 := OCR_X1 + OCR_W
        OCR_Y2 := OCR_Y1 + OCR_H

        ; Calculate center point of the box
        OCR_X3 := Round(OCR_X1 + OCR_W / 2)
        OCR_Y3 := Round(OCR_Y1 + OCR_H / 2)

        MsgBox,
        (LTrim
            ctrl+C to copy:
            FindOrLoseImage(%X1%, %Y1%, %X2%, %Y2%, , "%fileName%", 0, failSafeTime)
            FindImageAndClick(%X1%, %Y1%, %X2%, %Y2%, , "%fileName%", %X3%, %Y3%, sleepTime)
            adbClick_wbb(%X3%, %Y3%)
            OCR coordinates: %OCR_X3%, %OCR_Y3%, %OCR_W%, %OCR_H%
        )
    }
    catch {
        msgbox Failed to create screenshot GUI
    }
    CoordMode, Pixel, Screen
    return filePath
}

Screenshot(fileType := "Valid", subDir := "", ByRef fileName := "") {
    prof := Prof_Scope(A_ThisFunc)
    SetWorkingDir %A_ScriptDir%  ; Ensures the working directory is the script's directory

    ; Define folder and file paths
    fileDir := A_ScriptDir "\..\Screenshots"
    if !FileExist(fileDir)
        FileCreateDir, %fileDir%
    if (subDir) {
        fileDir .= "\" . subDir
        if !FileExist(fileDir)
            FileCreateDir, %fileDir%
    }
    if (filename = "PACKSTATS") {
        fileDir .= "\temp"
        if !FileExist(fileDir)
            FileCreateDir, %fileDir%
    }

    ; File path for saving the screenshot locally
    fileName := A_Now . "_" . session.get("scriptName") . "_" . fileType . "_" . session.get("packsInPool") . "_packs.png"
    if (filename = "PACKSTATS")
        fileName := "packstats_temp.png"
    filePath := fileDir "\" . fileName

    yBias := 40
    cropX := 18
    cropY := 170
    cropW := 240
    cropH := 227

    if (fileType = "FRIENDCODE"){
        cropX := 18
        cropY := 66
        cropW := 240
        cropH := 165
    }

    pBitmapW := from_window(getMuMuHwnd(session.get("winTitle")))
    pBitmap := Gdip_CloneBitmapArea(pBitmapW, cropX, cropY, cropW, cropH)

    Gdip_DisposeImage(pBitmapW)
    Gdip_SaveBitmapToFile(pBitmap, filePath)

    ; Don't dispose pBitmap if it's a PACKSTATS screenshot
    if (filename != "PACKSTATS") {
        Gdip_DisposeImage(pBitmap)
        return filePath
    }

    ; For PACKSTATS, return both values and delete temp file after OCR is done
    return {filepath: filePath, bitmap: pBitmap, deleteAfterUse: true}
}

bboxDraw2(X1, Y1, X2, Y2, color) {
    global session

    WinGetPos, xwin, ywin, Width, Height, % session.get("winTitle")
    BoxWidth := 10
    BoxHeight := 10
    Xm1:=X1-(BoxWidth/2)
    Xm2:=X2-(BoxWidth/2)
    Ym1:=Y1-(BoxWidth/2)
    Ym2:=Y2-(BoxWidth/2)
    Xh1:=Xm1+BoxWidth
    Xh2:=Xm2+BoxWidth
    Yh1:=Ym1+BoxHeight
    Yh2:=Ym2+BoxHeight

    ; Create a GUI
    guiSuffix := session.get("winTitle")
    Gui, BoundingBox%guiSuffix%:+AlwaysOnTop +ToolWindow -Caption +E0x20
    Gui, BoundingBox%guiSuffix%:Color, 123456
    Gui, BoundingBox%guiSuffix%:+LastFound  ; Make the GUI window the last found window for use by the line below. (straght from documentation)
    WinSet, TransColor, 123456 ; Makes that specific color transparent in the gui

    ; Create the borders and show
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%Xm1% y%Ym1% w%BoxWidth% h2 %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%Xm1% y%Ym1% w2 h%BoxHeight% %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%Xh1% y%Ym1% w2 h%BoxHeight% %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%Xm1% y%Yh1% w%BoxWidth% h2 %color%

    ; Create the borders and show
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%Xm2% y%Ym2% w%BoxWidth% h2 %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%Xm2% y%Ym2% w2 h%BoxHeight% %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%Xh2% y%Ym2% w2 h%BoxHeight% %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%Xm2% y%Yh2% w%BoxWidth% h2 %color%

    xshow := xwin
    yshow := ywin
    Gui, BoundingBox%guiSuffix%:Show, x%xshow% y%yshow% NoActivate
    Sleep, 100

}

adbSwipe_wbb(params) {
    prof := Prof_Scope(A_ThisFunc)
    global session

    if(session.get("dbg_bbox"))
        bboxAndPause_swipe(params, session.get("dbg_bboxNpause"))
    adbSwipe(params)
}

bboxAndPause_swipe(params, doPause := False) {
    global session

    guiSuffix := session.get("winTitle")
    paramsplit := StrSplit(params , " ")
    X1:=round(paramsplit[1] / 535 * 283)
    Y1:=round((paramsplit[2] / 960 * 488) + 40)
    X2:=round(paramsplit[3] / 535 * 283)
    Y2:=round((paramsplit[4] / 960 * 488) + 40)
    speed:=paramsplit[5]
    CreateStatusMessage("Swiping (" . X1 . "," . Y1 . ") to (" . X2 . "," . Y2 . ") speed " . speed,,,, false)

    color := "BackgroundYellow"

    ;bboxDraw2(X1, Y1, X2, Y2, color)

    bboxDraw(X1-5, Y1-5, X1+5, Y1+5, color)
    if (doPause) {
        Pause
    }
    Gui, BoundingBox%guiSuffix%:Destroy

    bboxDraw(X2-5, Y2-5, X2+5, Y2+5, color)
    if (doPause) {
        Pause
    }
    Gui, BoundingBox%guiSuffix%:Destroy
}
