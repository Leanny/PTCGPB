; Debug helpers that draw bounding boxes over the MuMu window

; Draws a rectangular bounding box overlay on the screen for debugging.
bboxDraw(X1, Y1, X2, Y2, color) {
    ; ------------------------------------------------------------------------------
    ; Parameters:
    ;   X1 (Int)    - Top-left X coordinate
    ;   Y1 (Int)    - Top-left Y coordinate
    ;   X2 (Int)    - Bottom-right X coordinate
    ;   Y2 (Int)    - Bottom-right Y coordinate
    ;   color (Str) - Color name for the box borders
    ;
    ; Creates a transparent GUI overlay with colored borders to show a region.
    ; ------------------------------------------------------------------------------
    global session

    WinGetPos, xwin, ywin, Width, Height, % "ahk_id " . getMuMuHwnd(session.get("winTitle"))
    BoxWidth := X2-X1
    BoxHeight := Y2-Y1
    ; Create a GUI
    guiSuffix := session.get("winTitle")
    Gui, BoundingBox%guiSuffix%:+AlwaysOnTop +ToolWindow -Caption +E0x20
    Gui, BoundingBox%guiSuffix%:Color, 123456
    Gui, BoundingBox%guiSuffix%:+LastFound  ; Make the GUI window the last found window for use by the line below. (straght from documentation)
    WinSet, TransColor, 123456 ; Makes that specific color transparent in the gui

    ; Create the borders and show
    Gui, BoundingBox%guiSuffix%:Add, Progress, x0 y0 w%BoxWidth% h2 %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x0 y0 w2 h%BoxHeight% %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x%BoxWidth% y0 w2 h%BoxHeight% %color%
    Gui, BoundingBox%guiSuffix%:Add, Progress, x0 y%BoxHeight% w%BoxWidth% h2 %color%

    xshow := X1+xwin
    yshow := Y1+ywin
    Gui, BoundingBox%guiSuffix%:Show, x%xshow% y%yshow% NoActivate
    Sleep, 100

}

; Displays a bounding box at click location for debugging purposes.
bboxAndPause_click(X, Y, doPause := False) {
    ; ------------------------------------------------------------------------------
    ; Parameters:
    ;   X (Int)       - X-coordinate center of box
    ;   Y (Int)       - Y-coordinate center of box
    ;   doPause (Bool) - Whether to pause execution after displaying box
    ;
    ; Shows a small box around the click point and optionally pauses for debugging.
    ; ------------------------------------------------------------------------------
    global session

    guiSuffix := session.get("winTitle")
    CreateStatusMessage("Clicking X " . X . " Y " . Y,,,, false)

    color := "BackgroundBlue"

    bboxDraw(X-5, Y-5, X+5, Y+5, color)

    if (doPause) {
        Pause
    }

    if GetKeyState("F4", "P") {
        Pause
    }
    Gui, BoundingBox%guiSuffix%:Destroy
}

; Displays a bounding box for image search debugging.
bboxAndPause_immage(X1, Y1, X2, Y2, pNeedleObj, vret := False, doPause := False) {
    ; ------------------------------------------------------------------------------
    ; Parameters:
    ;   X1 (Int)         - Top-left X coordinate of search region
    ;   Y1 (Int)         - Top-left Y coordinate of search region
    ;   X2 (Int)         - Bottom-right X coordinate of search region
    ;   Y2 (Int)         - Bottom-right Y coordinate of search region
    ;   pNeedleObj (Obj) - Needle object containing Name property
    ;   vret (Mixed)     - Return value from image search (for color coding)
    ;   doPause (Bool)   - Whether to pause if image found
    ;
    ; Shows green box if image found, red if not found.
    ; ------------------------------------------------------------------------------
    global session

    guiSuffix := session.get("winTitle")
    CreateStatusMessage("Searching " . pNeedleObj.Name . " returns " . vret,,,, false)

    if(vret>0) {
        color := "BackgroundGreen"
    } else {
        color := "BackgroundRed"
    }

    bboxDraw(X1, Y1, X2, Y2, color)

    if (doPause && vret) {
        Pause
    }

    if GetKeyState("F4", "P") {
        Pause
    }
    Gui, BoundingBox%guiSuffix%:Destroy
}

; Wrapper for adbClick with optional bounding box debugging display.
adbClick_wbb(X,Y)  {
    ; ------------------------------------------------------------------------------
    ; Parameters:
    ;   X (Int) - X-coordinate to click
    ;   Y (Int) - Y-coordinate to click
    ;
    ; If dbg_bbox global is enabled, shows a bounding box before clicking.
    ; ------------------------------------------------------------------------------
    prof := Prof_Scope(A_ThisFunc)
    global session

    if(session.get("dbg_bbox"))
        bboxAndPause_click(X, Y, session.get("dbg_bboxNpause"))
    adbClick(X,Y)
}
