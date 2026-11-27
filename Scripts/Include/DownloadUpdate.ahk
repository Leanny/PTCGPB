; In-game update data download (dialogs shown by Pokemon TCG Pocket after an update)

; Folder the game downloads its update data into (on the emulator).
global DOWNLOAD_DATA_FOLDER := "/data/media/0/Android/data/jp.pokemon.pokemontcgp/"

DownloadUpdate(notShowFinding := false, stallTimeoutSeconds := 3) {
    progressSeen := false
    if (FindOrLoseImage("Create_DownloadAlertWindow", 0, 0, 20, notShowFinding)) {
        ; The interrupted-battle prompt shares this pale needle. Its buttons
        ; are a light No on the left and a cyan Yes on the right, and the
        ; download tap (203,364) lands on Yes. Decline it instead.
        if (DownloadUpdate_IsResumeBattle()) {
            LogInfo("DownloadUpdate: interrupted battle prompt, declining")
            adbClick_wbb(80, 364) ; No
            Sleep, 800
            return true
        }
        LogInfo("DownloadUpdate: download alert found, starting download")
        adbClick_wbb(203, 364) ; start the download
    } else if (FindOrLoseImage("Create_DownloadingData", 0, 0, 30, notShowFinding)) {
        LogInfo("DownloadUpdate: download already in progress")
        progressSeen := true
    } else {
        if (FindOrLoseImage("Create_DownloadComplete", 0, 0, 20, notShowFinding)) {
            adbClick_wbb(140, 370)
            return true
        }
        return false
    }

    lastSize := GetDownloadFolderSizeKB()
    lastChange := A_TickCount
    grew := false
    progressGoneSince := 0
    Loop {
        Sleep, 1000

        if (FindOrLoseImage("Create_DownloadComplete", 0, 0, 20, true)) {
            adbClick_wbb(140, 370)
            LogInfo("DownloadUpdate: download complete")
            return true
        }

        ; Progress screen seen and gone for a few seconds: the game moved on.
        if (FindOrLoseImage("Create_DownloadingData", 0, 0, 30, true)) {
            progressSeen := true
            progressGoneSince := 0
        } else if (progressSeen) {
            if (progressGoneSince = 0)
                progressGoneSince := A_TickCount
            else if (A_TickCount - progressGoneSince >= 3000) {
                LogInfo("DownloadUpdate: download finished (" . Round(lastSize / 1024) . " MB)")
                return true
            }
        }

        size := GetDownloadFolderSizeKB()
        if (size > lastSize) {
            lastSize := size
            lastChange := A_TickCount
            grew := true
        }

        stalledSeconds := (A_TickCount - lastChange) // 1000
        CreateStatusMessage("Downloading update... " . Round(lastSize / 1024) . " MB`n(no change for " . stalledSeconds . "/" . stallTimeoutSeconds . " seconds)",,,, false)
        if (stalledSeconds >= stallTimeoutSeconds) {
            if (grew) {
                LogInfo("DownloadUpdate: download size stopped changing at " . Round(lastSize / 1024) . " MB, treating as finished")
                return true
            }
            LogWarn("DownloadUpdate: download size did not change for " . stallTimeoutSeconds . "s (" . Round(lastSize / 1024) . " MB), giving up")
            return false
        }
    }
}

; Size of the game's download folder in KB, or -1 if it could not be read.
GetDownloadFolderSizeKB() {
    global DOWNLOAD_DATA_FOLDER

    output := adbWriteRaw("du -sk " . DOWNLOAD_DATA_FOLDER . " 2>/dev/null", true, 10000)
    if (RegExMatch(Trim(output, "`r`n`t "), "^(\d+)", match))
        return match1 + 0
    return -1
}

; "Your battle was interrupted. Do you want to resume it?"
; Light No at (50,365) and (105,365), cyan Yes at (165,365) and (230,365).
; Measured on instance 6: No's label is (80,364), Yes is (203,364).
DownloadUpdate_IsResumeBattle() {
    global session
    pBitmap := from_window(getMuMuHwnd(session.get("winTitle")))
    if (!pBitmap)
        return false
    resume := DownloadUpdate_IsLight(pBitmap, 50, 365) && DownloadUpdate_IsLight(pBitmap, 105, 365) && DownloadUpdate_IsCyan(pBitmap, 165, 365) && DownloadUpdate_IsCyan(pBitmap, 230, 365)
    Gdip_DisposeImage(pBitmap)
    return resume
}

DownloadUpdate_IsCyan(pBitmap, x, y) {
    DownloadUpdate_Pixel(pBitmap, x, y, r, g, b)
    return (b >= 225 && g >= 180 && r <= 190 && (b - r) >= 55)
}

DownloadUpdate_IsLight(pBitmap, x, y) {
    DownloadUpdate_Pixel(pBitmap, x, y, r, g, b)
    mx := (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b)
    mn := (r < g) ? ((r < b) ? r : b) : ((g < b) ? g : b)
    return (r >= 205 && g >= 205 && b >= 205 && (mx - mn) <= 40)
}

DownloadUpdate_Pixel(pBitmap, x, y, ByRef r, ByRef g, ByRef b) {
    ARGB := Gdip_GetPixel(pBitmap, x, y)
    r := (ARGB >> 16) & 0xFF
    g := (ARGB >> 8) & 0xFF
    b := ARGB & 0xFF
}
