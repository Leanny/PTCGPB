;===============================================================================
; PTCGPHelper.ahk - Android ptcgpb helper install/runtime utilities
;===============================================================================

;-------------------------------------------------------------------------------
; Pack name → Expansion ID mapping for --pack favourite command
;-------------------------------------------------------------------------------
GetExpansionIdForPack(packName) {
    static map := ""
    if (map = "") {
        map := {}
        ; A1 - Genetic Apex (3 packs)
        map["Mewtwo"] := "A1"
        map["Charizard"] := "A1"
        map["Pikachu"] := "A1"
        ; A1a - Mythical Island (1 pack)
        map["Mew"] := "A1a"
        ; A2 - Space-Time Smackdown (2 packs)
        map["Dialga"] := "A2"
        map["Palkia"] := "A2"
        ; A2a - Triumphant Light (1 pack)
        map["Arceus"] := "A2a"
        ; A2b - Shining Revelry (1 pack)
        map["Shining"] := "A2b"
        ; A3 - Celestial Guardians (2 packs)
        map["Solgaleo"] := "A3"
        map["Lunala"] := "A3"
        ; A3a - Extradimensional Crisis (1 pack)
        map["Buzzwole"] := "A3a"
        ; A3b - Eevee Grove (1 pack)
        map["Eevee"] := "A3b"
        ; A4 - Wisdom of Sea and Sky (2 packs)
        map["HoOh"] := "A4"
        map["Lugia"] := "A4"
        ; A4a - Secluded Springs (1 pack)
        map["Springs"] := "A4a"
        ; A4b - Deluxe Pack: ex (1 pack)
        map["Deluxe"] := "A4b"
        ; B1 - Mega Rising (3 packs)
        map["MegaGyarados"] := "B1"
        map["MegaBlaziken"] := "B1"
        map["MegaAltaria"] := "B1"
        ; B1a - Crimson Blaze (1 pack)
        map["CrimsonBlaze"] := "B1a"
        ; B2 - Fantastical Parade (1 pack)
        map["Parade"] := "B2"
        ; B2a - Paldean Wonders (1 pack)
        map["PaldeanWonders"] := "B2a"
        ; B2b - Mega Shine (1 pack)
        map["MegaShine"] := "B2b"
        ; B3 - Pulsing Aura (1 pack)
        map["PulsingAura"] := "B3"
        ; B3a - Paradox Drive (1 pack)
        map["ParadoxDrive"] := "B3a"
        ; B3b - Everyday Wonders (1 pack)
        map["EverydayWonders"] := "B3b"
        ; B4 - Ruler of the Skies (1 pack)
        map["RulerOfTheSkies"] := "B4"
    }
    return map[packName]
}

;-------------------------------------------------------------------------------
; Get the X coordinate for a pack in the Points screen (Y=320) based on its
; position within the expansion. The Points screen always shows one pack in
; the centre; a second pack (if any) is to its right; a third (if any) is to
; the left.
;-------------------------------------------------------------------------------
GetPackFavoritePointsX(packName) {
    global session
    packInfo := session.get("pokemonPackObj")[packName]
    if (!IsObject(packInfo))
        return 140
    pos := packInfo["PositionInExtension"]
    numOfPacks := packInfo["NumOfPackInSet"]
    ; Position suffix determines left/centre/right within the expansion.
    isLeft := InStr(pos, "-Left")
    isMiddle := InStr(pos, "-Middle")
    isRight := InStr(pos, "-Right")
    if (numOfPacks = 3) {
        if (isLeft)
            return 60
        else if (isMiddle)
            return 140
        else if (isRight)
            return 215
    }
    else if (numOfPacks = 2) {
        if (isLeft)
            return 140
        else if (isRight)
            return 215
    }
    return 140
}

;-------------------------------------------------------------------------------
; Get the X coordinate for a pack in the Home favourites view (Y=203).
; Favourites show packs symmetrically: 3 packs use Left/Center/Right,
; 2 packs use symmetric Left/Right around centre.
;-------------------------------------------------------------------------------
GetPackFavoriteHomeX(packName) {
    global session
    packInfo := session.get("pokemonPackObj")[packName]
    if (!IsObject(packInfo))
        return 140
    pos := packInfo["PositionInExtension"]
    numOfPacks := packInfo["NumOfPackInSet"]
    isLeft := InStr(pos, "-Left")
    isMiddle := InStr(pos, "-Middle")
    isRight := InStr(pos, "-Right")
    if (numOfPacks = 3) {
        if (isLeft)
            return 60
        else if (isMiddle)
            return 140
        else if (isRight)
            return 215
    }
    else if (numOfPacks = 2) {
        if (isLeft)
            return 90
        else if (isRight)
            return 190
    }
    return 140
}

;-------------------------------------------------------------------------------
; SetPackFavorite - set the favourite expansion via ptcgpb helper --pack command.
; Must be called while the game is closed. Returns true on success.
;-------------------------------------------------------------------------------
SetPackFavorite(packName) {
    global session

    expansionId := GetExpansionIdForPack(packName)
    if (expansionId = "") {
        LogWarn("SetPackFavorite: unknown pack name '" . packName . "', skipping")
        return false
    }

    if (!EnsurePTCGPBHelperInstalled()) {
        LogWarn("SetPackFavorite: helper not installed, skipping")
        return false
    }

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    output := Trim(CmdRet(adbCommand . " shell /data/ptcgp/ptcgpb --pack " . expansionId), "`r`n`t ")
    LogInfo("SetPackFavorite: pack=" . packName . " expansion=" . expansionId . " result=" . output, "ADB.txt")

    if (InStr(output, "True") || output = "")
        return true
    return (InStr(output, "True"))
}

; Run ptcgpb via a one-off adb shell so the persistent shell is not desynced by nohup.
StartPtcgpbWatchCards(full := false) {
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    if (full)
        watchArgs := " watch-cards --full --duplicate"
    else
        watchArgs := " watch-cards --duplicate"
    RunWait, % adbCommand . " shell ""nohup /data/ptcgp/ptcgpb" . watchArgs . " >/dev/null 2>&1 </dev/null &""", , Hide
    Sleep, 300
    return true
}

; True once the watch-cards Helper has written a card result (result.rc).
HelperHasCardResult() {
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    ; Use test -s so we only consider the result valid when the file has actual content.
    RunWait, % adbCommand . " shell test -s /data/ptcgp/result.rc", , Hide
    return (ErrorLevel = 0)
}

GetPtcgpbPackCount() {
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    output := Trim(CmdRet(adbCommand . " shell /data/ptcgp/ptcgpb packcount"), "`r`n`t ")
    output := StrReplace(output, "`r")
    output := Trim(output, "`n ")
    if !RegExMatch(output, "^-?\d+$") {
        LogDebug("GetPtcgpbPackCount returned non-numeric output: " . output)
        return 0
    }

    LogDebug("GetPtcgpbPackCount result=" . output)
    return output + 0
}

EnsurePTCGPBHelperInstalled() {
    global session

    remotePath := "/data/ptcgp/ptcgpb"
    safeScriptName := RegExReplace(session.get("scriptName"), "[^A-Za-z0-9_.-]", "_")
    if (safeScriptName = "")
        safeScriptName := A_ScriptName
    remoteTmpPath := "/data/ptcgp/ptcgpb." . safeScriptName . ".tmp"
    sdcardTmpPath := "/sdcard/ptcgpb-helper." . safeScriptName . ".tmp"
    helperUrl := "https://leanny.github.io/ptcgpb-helper/ptcgpb-helper-android"
    localPath := A_Temp . "\ptcgpb-helper-android." . safeScriptName
    minHelperSize := 2500000
    adbWriteRaw("mkdir -p /data/ptcgp")
    RepairPtcgpbRarityCache()
    remoteSize := Trim(StrReplace(adbWriteRaw("if [ -x " . remotePath . " ]; then wc -c < " . remotePath . "; else echo 0; fi", true), "`r"), "`n`t ")
    remoteSize := RegExReplace(remoteSize, "[^\d]")
    if (remoteSize >= minHelperSize) {
        LogTrace("ptcgpb helper already exists on device size=" . remoteSize, "ADB.txt")
        return true
    }
    if (remoteSize > 0) {
        LogWarn("Removing incomplete ptcgpb helper from device size=" . remoteSize)
        adbWriteRaw("rm -f " . remotePath)
    }

    LogInfo("ptcgpb helper missing on device; downloading on Windows host")
    if (!DownloadPTCGPBHelperToFile(helperUrl, localPath)) {
        LogWarn("Failed to download ptcgpb helper on Windows host")
        return false
    }

    FileGetSize, helperSize, %localPath%
    if (helperSize < minHelperSize) {
        LogWarn("Downloaded ptcgpb helper is unexpectedly small: " . helperSize . " bytes")
        return false
    }
    adbCommand := """" . session.get("adbPath") . """ -s 127.0.0.1:" . session.get("adbPort")
    LogTrace("Pushing ptcgpb helper to " . sdcardTmpPath, "ADB.txt")
    RunWait, % adbCommand . " push """ . localPath . """ " . sdcardTmpPath,, Hide

    if (ErrorLevel) {
        LogWarn("Failed to push ptcgpb helper to device. ErrorLevel=" . ErrorLevel)
        return false
    }

    adbWriteRaw("cp -f " . sdcardTmpPath . " " . remoteTmpPath . " && mv -f " . remoteTmpPath . " " . remotePath . " && chmod 777 " . remotePath . " && rm -f " . sdcardTmpPath)
    remoteSize := Trim(StrReplace(adbWriteRaw("if [ -x " . remotePath . " ]; then wc -c < " . remotePath . "; else echo 0; fi", true), "`r"), "`n`t ")
    remoteSize := RegExReplace(remoteSize, "[^\d]")
    if (remoteSize < minHelperSize) {
        LogWarn("ptcgpb helper install verification failed size=" . remoteSize)
        return false
    }

    LogInfo("ptcgpb helper installed via Windows download and adb push")
    return true
}

RepairPtcgpbRarityCache() {
    cachePath := "/data/ptcgp/.card/cardrarity.json"
    minCacheSize := 1000
    cacheSize := Trim(adbWriteRaw("if [ -f " . cachePath . " ]; then wc -c < " . cachePath . "; else echo missing; fi", true), "`r`n`t ")

    if (cacheSize = "missing") {
        LogTrace("ptcgpb rarity cache does not exist; helper will build it", "ADB.txt")
        return false
    }

    if (!RegExMatch(cacheSize, "^\d+$")) {
        LogWarn("Could not determine ptcgpb rarity cache size: " . cacheSize, "ADB.txt")
        return false
    }

    cacheSize += 0
    if (cacheSize >= minCacheSize) {
        LogTrace("ptcgpb rarity cache is valid size=" . cacheSize, "ADB.txt")
        return false
    }

    LogWarn("Removing incomplete ptcgpb rarity cache size=" . cacheSize)
    adbWriteRaw("rm -f " . cachePath)
    return true
}

DownloadPTCGPBHelperToFile(url, localPath) {
    RegRead, proxyEnabled, HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings, ProxyEnable
    RegRead, proxyServer, HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings, ProxyServer

    whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
    if (proxyEnabled)
        whr.SetProxy(2, proxyServer)
    whr.SetTimeouts(10000, 10000, 30000, 120000)
    whr.Open("GET", url, false)
    whr.Send()

    if (whr.Status != 200) {
        LogWarn("ptcgpb helper host download returned HTTP status " . whr.Status)
        return false
    }

    if (FileExist(localPath))
        FileDelete, %localPath%

    stream := ComObjCreate("ADODB.Stream")
    stream.Type := 1
    stream.Open()
    stream.Write(whr.ResponseBody)
    stream.SaveToFile(localPath, 2)
    stream.Close()
    return FileExist(localPath)
}

RemoveOldFiles() {
    remotePath := "/data/ptcgp/ptcgpb"
    exists := Trim(StrReplace(adbWriteRaw("if [ -f " . remotePath . " ]; then echo 1; else echo 0; fi", true), "`r"), "`n`t ")
    if (exists != "1") {
        LogTrace("RemoveOldFiles skipped because ptcgpb helper does not exist", "ADB.txt")
        return
    }

    versionOutput := adbWriteRaw(remotePath . " --version", true)
    if (!RegExMatch(versionOutput, "(\d+)\.(\d+)\.(\d+)", versionMatch)) {
        LogWarn("RemoveOldFiles skipped because ptcgpb helper version could not be parsed: " . Trim(versionOutput), "ADB.txt")
        return
    }

    if (IsPtcgpbVersionLessThan(versionMatch1, versionMatch2, versionMatch3, 0, 10, 4)) {
        LogInfo("RemoveOldFiles deleting old ptcgpb helper version " . versionMatch1 . "." . versionMatch2 . "." . versionMatch3, "ADB.txt")
        adbWriteRaw("rm -f " . remotePath)
    } else {
        LogTrace("RemoveOldFiles kept ptcgpb helper version " . versionMatch1 . "." . versionMatch2 . "." . versionMatch3, "ADB.txt")
    }
}

IsPtcgpbVersionLessThan(major, minor, patch, minMajor, minMinor, minPatch) {
    major += 0
    minor += 0
    patch += 0

    if (major != minMajor)
        return major < minMajor
    if (minor != minMinor)
        return minor < minMinor
    return patch < minPatch
}
