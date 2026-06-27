;-------------------------------------------------------------------------------
; MumuHelper.ahk - MuMu Player helper functions
;-------------------------------------------------------------------------------

getMuMuFolderInConfig(){
    jsonPath := A_AppData . "\Netease\MuMuPlayerGlobal\install_config.json"

    if (!FileExist(jsonPath)) {
        return -1
    }

    FileRead, jsonText, %jsonPath%

    if (RegExMatch(jsonText, "U)""install_dir""\s*:\s*""(.*)""", match)) {
        rawPath := match1
        fullPath := StrReplace(rawPath, "\\", "\")

        ;SplitPath, fullPath,, parentDir

        if (InStr(FileExist(fullPath), "D")) {
            return fullPath
        } else {
            return -2
        }
    } else {
        return -3
    }
}

getMuMuFolder() {
    global botConfig
    static subFolderList

    mumuFolder := getMuMuFolderInConfig()

    if(!IsNumeric(mumuFolder))
        return mumuFolder

    baseFolder := botConfig.get("folderPath")
    subFolderList := ["", "MuMuPlayerGlobal-12.0", "MuMu Player 12", "MuMuPlayer-12.0", "MuMuPlayer", "MuMuPlayer-12", "MuMuPlayer12"]

    For idx, value in subFolderList {
        mumuFolder = %baseFolder%\%value%
        if InStr(FileExist(mumuFolder), "D")
            return mumuFolder
    }

    MsgBox, 16, , Can't Find MuMu, try old MuMu installer in Discord #announcements, otherwise double check your folder path setting!`nDefault path is C:\Program Files\Netease
    return
}

MuMuIsV5() {
    mumuFolder := getMuMuFolder()
    return (mumuFolder != "" && InStr(FileExist(mumuFolder . "\nx_main"), "D"))
}

MuMuBias() {
    if(MuMuIsV5())
        return 0
    return -4
}

MuMuGetInstanceIndex(name) {
    output := MuMuManagerCommand("info -v all", true)
    if (output = "")
        return ""

    pos := 1
    while (foundPos := RegExMatch(output, "s)""([^""]+)""\s*:\s*\{(.*?)\}", match, pos)) {
        objectKey := match1
        objectBody := match2
        if (MuMuJsonStringValue(objectBody, "name") = name)
            return objectKey
        pos := foundPos + StrLen(match)
    }

    return ""
}

MuMuStart(instance) {
    return MuMuManagerCommand("control launch -v " . MuMuQuoteArg(instance))
}

MuMuShutdownInstance(instance) {
    return MuMuManagerCommand("control shutdown -v " . MuMuQuoteArg(instance))
}

MuMuRestart(instance) {
    return MuMuManagerCommand("control restart -v " . MuMuQuoteArg(instance))
}

MuMuSetSetting(instance, key, value) {
    return MuMuManagerCommand("setting -v " . MuMuQuoteArg(instance) . " -k " . MuMuQuoteArg(key) . " -val " . MuMuQuoteArg(value))
}

MuMuEnableRoot(instance) {
    MuMuSetSetting(instance, "root_permission", "true")
    Sleep, 100
}

MuMuDisableRoot(instance) {
    MuMuSetSetting(instance, "root_permission", "false")
    Sleep, 100
}

isMuMuV5() {
    return MuMuIsV5()
}

getMuMuInstanceIndex(name) {
    return MuMuGetInstanceIndex(name)
}

startMuMu(instance) {
    return MuMuStart(instance)
}

shutdownMuMuInstance(instance) {
    return MuMuShutdownInstance(instance)
}

restartMuMu(instance) {
    return MuMuRestart(instance)
}

setMuMuSetting(instance, key, value) {
    return MuMuSetSetting(instance, key, value)
}

MuMuManagerCommand(args, captureOutput := false) {
    mumuFolder := getMuMuFolder()
    if (mumuFolder = "")
        return ""

    managerPath := mumuFolder . "\shell\MuMuManager.exe"
    if (!FileExist(managerPath)) {
        managerPath := mumuFolder . "\nx_main\MuMuManager.exe"
        if (!FileExist(managerPath))
            return ""
    }

    command := """" . managerPath . """ " . args
    if (captureOutput && IsFunc("CmdRet"))
        return CmdRet(command)

    RunWait, %command%,, Hide
    return !ErrorLevel
}

MuMuJsonStringValue(json, key) {
    needle := """" . key . """\s*:\s*""((?:[^""\\]|\\.)*)"""
    if (!RegExMatch(json, needle, match))
        return ""

    value := match1
    value := StrReplace(value, "\""", """")
    value := StrReplace(value, "\\", "\")
    value := StrReplace(value, "\/", "/")
    value := StrReplace(value, "\n", "`n")
    value := StrReplace(value, "\r", "`r")
    value := StrReplace(value, "\t", A_Tab)
    return value
}

MuMuQuoteArg(value) {
    return """" . value . """"
}
