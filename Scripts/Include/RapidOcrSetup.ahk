;-------------------------------------------------------------------------------
; RapidOcrSetup.ahk - on-demand installer for the RapidOCR-json engine.
;
; Install location (what the OCR callers search for):
;   rapidocr\RapidOCR-json_v0.2.0\RapidOCR-json.exe
;   rapidocr\RapidOCR-json_v0.2.0\models\*
;-------------------------------------------------------------------------------

RapidOcr_ArchiveUrl() {
    return "https://github.com/hiroi-sora/RapidOCR-json/releases/download/v0.2.0/RapidOCR-json_v0.2.0.7z"
}

RapidOcr_ArchiveSize() {
    return 73461693
}

; Pinned: the archive is only installed if it matches this hash.
RapidOcr_ArchiveSha256() {
    return "7AD9B283D03436C6CD0296723188699299CB4E5CF9140B410C59543AA5793C40"
}

; Total size of the extracted archive, only used to estimate extraction progress.
RapidOcr_ExtractedSize() {
    return 95442176
}

RapidOcr_InstallDir(baseDir := "") {
    if (baseDir = "")
        baseDir := A_ScriptDir
    return baseDir . "\rapidocr\RapidOCR-json_v0.2.0"
}

; The engine plus the models/keysets the bot actually uses (det + cls, the
; default recognizer, the v4 recognizer and the CJK recognizers).
RapidOcr_RequiredFiles() {
    return ["RapidOCR-json.exe"
        , "models\configs.txt"
        , "models\ch_PP-OCRv3_det_infer.onnx"
        , "models\ch_PP-OCRv3_rec_infer.onnx"
        , "models\ch_PP-OCRv4_det_infer.onnx"
        , "models\ch_ppocr_mobile_v2.0_cls_infer.onnx"
        , "models\rec_ch_PP-OCRv4_infer.onnx"
        , "models\dict_chinese.txt"
        , "models\ppocr_keys_v1.txt"
        , "models\rec_japan_PP-OCRv3_infer.onnx"
        , "models\dict_japan.txt"
        , "models\rec_korean_PP-OCRv3_infer.onnx"
        , "models\dict_korean.txt"
        , "models\rec_chinese_cht_PP-OCRv3_infer.onnx"
        , "models\dict_chinese_cht.txt"]
}

RapidOcr_IsInstalled(baseDir := "") {
    installDir := RapidOcr_InstallDir(baseDir)
    for _, rel in RapidOcr_RequiredFiles() {
        if (!FileExist(installDir . "\" . rel))
            return false
    }
    return true
}

; Startup check. Returns true if RapidOCR is available afterwards.
RapidOcr_EnsureInstalled(baseDir := "") {
    if (RapidOcr_IsInstalled(baseDir))
        return true

    sizeMb := Round(RapidOcr_ArchiveSize() / 1048576)
    message := "Some bot modes need the RapidOCR text recognition engine.`n"
        . "It is not included with the bot. Click OK to download it now (about " . sizeMb . " MB).`n"
        . "If you click Cancel, some modes will not work, and you will be asked again the next time the bot starts."
    MsgBox, 0x41, RapidOCR Required, %message%
    IfMsgBox, Cancel
    {
        LogInfo("RapidOCR missing; user declined the download")
        return false
    }

    return RapidOcr_DownloadAndInstall(baseDir)
}

RapidOcr_DownloadAndInstall(baseDir := "") {
    global g_rapidOcrCancel, g_rapidOcrUi
    g_rapidOcrCancel := false

    installDir := RapidOcr_InstallDir(baseDir)
    SplitPath, installDir,, ocrRoot
    tempRoot := A_Temp . "\PTCGPB_RapidOCR_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
    staging := tempRoot . "\extract"
    FileCreateDir, %staging%
    if (!FileExist(staging)) {
        MsgBox, 0x40010, RapidOCR Setup, Could not create the temporary folder:`n%tempRoot%
        return false
    }

    LogInfo("RapidOCR download started")
    RapidOcr_ShowProgress()
    err := RapidOcr_RunSteps(baseDir, installDir, ocrRoot, tempRoot, staging)
    RapidOcr_CloseProgress()
    FileRemoveDir, %tempRoot%, 1

    if (err = "") {
        LogInfo("RapidOCR installed to " . installDir)
        return true
    }
    if (err = "CANCEL") {
        LogInfo("RapidOCR download cancelled by user")
        MsgBox, 0x40040, RapidOCR Setup, The download was cancelled.`n`nModes that need RapidOCR will not work. You will be asked again the next time the bot starts.
        return false
    }
    LogError("RapidOCR setup failed: " . err)
    MsgBox, 0x40010, RapidOCR Setup, RapidOCR could not be set up:`n`n%err%`n`nYou will be asked again the next time the bot starts.
    return false
}

; Runs download, verify, extract and install. Returns "" on success, "CANCEL"
; if the user cancelled, or an error message.
RapidOcr_RunSteps(baseDir, installDir, ocrRoot, tempRoot, staging) {
    archive := tempRoot . "\rapidocr.7z"
    total := RapidOcr_ArchiveSize()

    ; ---- Step 1: download (bar 0 - 800) ----
    RapidOcr_SetStep("Step 1 of 4: Downloading RapidOCR", "Connecting...", 0)
    result := RapidOcr_Download(archive, tempRoot)
    if (result != "")
        return result

    ; ---- Step 2: verify (bar 800 - 850) ----
    RapidOcr_SetStep("Step 2 of 4: Verifying download", "Checking SHA-256 checksum...", 800)
    FileGetSize, archiveSize, %archive%
    if (archiveSize != total)
        return "The downloaded file has an unexpected size (" . archiveSize . " bytes, expected " . total . ")."
    hashFile := tempRoot . "\hash.txt"
    psExe := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
    psCmd := """" . psExe . """ -NoProfile -NonInteractive -Command ""(Get-FileHash -LiteralPath '"
        . StrReplace(archive, "'", "''") . "' -Algorithm SHA256).Hash | Set-Content -LiteralPath '"
        . StrReplace(hashFile, "'", "''") . "' -Encoding ASCII"""
    if (RapidOcr_RunPump(psCmd, "") = "CANCEL")
        return "CANCEL"
    FileRead, actualHash, %hashFile%
    actualHash := Trim(actualHash, " `t`r`n")
    if (actualHash != RapidOcr_ArchiveSha256())
        return "The downloaded file failed SHA-256 verification and was not installed.`n`nExpected: " . RapidOcr_ArchiveSha256() . "`nActual:   " . actualHash

    ; ---- Step 3: extract (bar 850 - 950) ----
    RapidOcr_SetStep("Step 3 of 4: Extracting", "Unpacking archive...", 850)
    tarExe := A_WinDir . "\System32\tar.exe"
    if (!FileExist(tarExe))
        return "Windows' built-in tar.exe was not found, so the archive cannot be extracted.`n`nExtract " . archive . " manually into " . installDir
    tarErr := tempRoot . "\tar.err"
    tarCmd := ComSpec . " /c """ . """" . tarExe . """ -xf """ . archive . """ -C """ . staging . """ 2> """ . tarErr . """"""
    progressFn := Func("RapidOcr_ExtractProgress").Bind(staging)
    if (RapidOcr_RunPump(tarCmd, progressFn) = "CANCEL")
        return "CANCEL"
    extractedRoot := staging . "\RapidOCR-json_v0.2.0"
    if (!FileExist(extractedRoot . "\RapidOCR-json.exe")) {
        FileRead, tarText, %tarErr%
        return "Extracting the archive failed." . (Trim(tarText) != "" ? "`n`n" . Trim(tarText) : "")
    }

    ; ---- Step 4: install (bar 950 - 1000) ----
    RapidOcr_SetStep("Step 4 of 4: Installing", "Copying files...", 950)
    partialDir := installDir . ".partial"
    if (FileExist(partialDir))
        FileRemoveDir, %partialDir%, 1
    required := RapidOcr_RequiredFiles()
    for index, rel in required {
        src := extractedRoot . "\" . rel
        dst := partialDir . "\" . rel
        SplitPath, dst,, dstDir
        FileCreateDir, %dstDir%
        FileCopy, %src%, %dst%, 1
        if (ErrorLevel) {
            FileRemoveDir, %partialDir%, 1
            return "Could not copy " . rel . " into " . ocrRoot . "."
        }
        RapidOcr_SetProgress(950 + Round(index / required.Length() * 50), "Copying files... (" . index . "/" . required.Length() . ")")
    }
    if (FileExist(installDir))
        FileRemoveDir, %installDir%, 1
    FileMoveDir, %partialDir%, %installDir%, R
    if (ErrorLevel || !RapidOcr_IsInstalled(baseDir)) {
        FileRemoveDir, %partialDir%, 1
        return "Could not finish installing into " . installDir . "."
    }

    RapidOcr_SetStep("Done", "RapidOCR is ready.", 1000)
    Sleep, 700
    return ""
}

; Downloads the archive with curl.exe (ships with Windows 10 1803+), falling back
; to PowerShell, and shows bytes, speed and ETA by polling the file size.
RapidOcr_Download(dest, tempRoot) {
    global g_rapidOcrCancel
    total := RapidOcr_ArchiveSize()
    url := RapidOcr_ArchiveUrl()
    errFile := tempRoot . "\download.err"
    curlExe := A_WinDir . "\System32\curl.exe"
    if (FileExist(curlExe)) {
        cmd := ComSpec . " /c """ . """" . curlExe . """ -L --fail --silent --show-error --connect-timeout 20 -o """ . dest . """ """ . url . """ 2> """ . errFile . """"""
    } else {
        psExe := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
        cmd := ComSpec . " /c """ . """" . psExe . """ -NoProfile -NonInteractive -Command ""[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri '"
            . url . "' -OutFile '" . StrReplace(dest, "'", "''") . "'"" 2> """ . errFile . """"""
    }

    Run, %cmd%,, Hide UseErrorLevel, pid
    if (ErrorLevel || !pid)
        return "Could not start the download."

    startTick := A_TickCount
    lastTick := startTick
    lastSize := 0
    speed := 0
    size := 0
    Loop {
        if (g_rapidOcrCancel) {
            RapidOcr_KillTree(pid)
            return "CANCEL"
        }
        FileGetSize, size, %dest%
        if (ErrorLevel)
            size := 0
        now := A_TickCount
        if (now - lastTick >= 500) {
            instant := (size - lastSize) / ((now - lastTick) / 1000)
            speed := (speed = 0) ? instant : speed * 0.6 + instant * 0.4
            lastTick := now
            lastSize := size
        }
        detail := RapidOcr_Mb(size) . " / " . RapidOcr_Mb(total) . " MB  (" . Round(size / total * 100) . "%)"
        if (speed > 0) {
            detail .= "   " . RapidOcr_Mb(speed) . " MB/s"
            remaining := (total - size) / speed
            detail .= "   ETA " . RapidOcr_FormatSeconds(remaining)
        }
        RapidOcr_SetProgress(Round(Min(size / total, 1) * 800), detail)

        Process, Exist, %pid%
        if (!ErrorLevel)
            break
        Sleep, 100
    }

    FileGetSize, size, %dest%
    if (ErrorLevel)
        size := 0
    if (size != total) {
        FileRead, errText, %errFile%
        errText := Trim(errText, " `t`r`n")
        return "The download failed (" . RapidOcr_Mb(size) . " of " . RapidOcr_Mb(total) . " MB received)." . (errText != "" ? "`n`n" . errText : "`n`nCheck your internet connection and firewall.")
    }
    RapidOcr_SetProgress(800, RapidOcr_Mb(total) . " / " . RapidOcr_Mb(total) . " MB  (100%)")
    return ""
}

; Runs a hidden command while keeping the progress window responsive.
; progressFn (optional) is called every tick. Returns "CANCEL" or "".
RapidOcr_RunPump(cmd, progressFn) {
    global g_rapidOcrCancel
    Run, %cmd%,, Hide UseErrorLevel, pid
    if (ErrorLevel || !pid)
        return ""
    Loop {
        if (g_rapidOcrCancel) {
            RapidOcr_KillTree(pid)
            return "CANCEL"
        }
        if (IsObject(progressFn))
            progressFn.Call()
        Process, Exist, %pid%
        if (!ErrorLevel)
            break
        Sleep, 100
    }
    return ""
}

RapidOcr_ExtractProgress(staging) {
    bytes := 0
    Loop, Files, %staging%\*, FR
        bytes += A_LoopFileSize
    fraction := Min(bytes / RapidOcr_ExtractedSize(), 1)
    RapidOcr_SetProgress(850 + Round(fraction * 100), RapidOcr_Mb(bytes) . " / " . RapidOcr_Mb(RapidOcr_ExtractedSize()) . " MB extracted")
}

RapidOcr_KillTree(pid) {
    RunWait, %ComSpec% /c taskkill /F /T /PID %pid%, , Hide UseErrorLevel
}

RapidOcr_Mb(bytes) {
    return Round(bytes / 1048576, 1)
}

RapidOcr_FormatSeconds(seconds) {
    seconds := Round(seconds)
    if (seconds >= 60)
        return Floor(seconds / 60) . "m " . Mod(seconds, 60) . "s"
    return seconds . "s"
}

;-------------------------------------------------------------------------------
; Progress window
;-------------------------------------------------------------------------------
RapidOcr_ShowProgress() {
    global g_rapidOcrUi
    g_rapidOcrUi := {}
    Gui, RapidOcrSetup:Destroy
    Gui, RapidOcrSetup:+AlwaysOnTop -SysMenu +HwndhGui
    Gui, RapidOcrSetup:Color, 1E1E1E, 333333
    Gui, RapidOcrSetup:Font, s11 cWhite, Segoe UI
    Gui, RapidOcrSetup:Add, Text, x20 y15 w440, Setting up RapidOCR
    Gui, RapidOcrSetup:Font, s9 cWhite, Segoe UI
    Gui, RapidOcrSetup:Add, Text, x20 y48 w440 h18 +HwndhStep, Preparing...
    Gui, RapidOcrSetup:Add, Progress, x20 y72 w440 h20 Range0-1000 -Smooth -Theme c4AAE3A Background333333 +HwndhBar, 0
    Gui, RapidOcrSetup:Font, s9 cSilver, Segoe UI
    Gui, RapidOcrSetup:Add, Text, x20 y100 w440 h18 +HwndhDetail
    Gui, RapidOcrSetup:Font, s9 cWhite, Segoe UI
    Gui, RapidOcrSetup:Add, Button, x190 y132 w100 h28 +HwndhCancel, Cancel
    g_rapidOcrUi.step := hStep
    g_rapidOcrUi.bar := hBar
    g_rapidOcrUi.detail := hDetail
    g_rapidOcrUi.cancel := hCancel
    cancelFn := Func("RapidOcr_CancelClicked")
    GuiControl, RapidOcrSetup:+g, %hCancel%, % cancelFn
    Gui, RapidOcrSetup:Show, w480 h175, RapidOCR Setup
}

RapidOcr_CloseProgress() {
    Gui, RapidOcrSetup:Destroy
}

RapidOcr_CancelClicked(args*) {
    global g_rapidOcrCancel, g_rapidOcrUi
    g_rapidOcrCancel := true
    GuiControl, RapidOcrSetup:, % g_rapidOcrUi.detail, Cancelling...
    GuiControl, RapidOcrSetup:Disable, % g_rapidOcrUi.cancel
}

RapidOcr_SetStep(step, detail, pos) {
    global g_rapidOcrUi
    GuiControl, RapidOcrSetup:, % g_rapidOcrUi.step, %step%
    RapidOcr_SetProgress(pos, detail)
}

RapidOcr_SetProgress(pos, detail) {
    global g_rapidOcrUi, g_rapidOcrCancel
    GuiControl, RapidOcrSetup:, % g_rapidOcrUi.bar, %pos%
    if (!g_rapidOcrCancel)
        GuiControl, RapidOcrSetup:, % g_rapidOcrUi.detail, %detail%
}
