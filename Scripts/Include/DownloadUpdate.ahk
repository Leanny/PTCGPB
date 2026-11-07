; In-game update data download (dialogs shown by Pokemon TCG Pocket after an update)

; Folder the game downloads its update data into (on the emulator).
global DOWNLOAD_DATA_FOLDER := "/data/media/0/Android/data/jp.pokemon.pokemontcgp/"

DownloadUpdate(notShowFinding := false, stallTimeoutSeconds := 10) {
    progressSeen := false
    if (FindOrLoseImage("Create_DownloadAlertWindow", 0, 0, 20, notShowFinding)) {
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
