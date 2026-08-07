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
    static instanceIndexes := {}
    static instanceIndexesLoaded := false

    if (instanceIndexesLoaded)
        return instanceIndexes.HasKey(name) ? instanceIndexes[name] : ""

    output := MuMuManagerCommand("info -v all", true)
    if (output = "")
        return ""

    pos := 1
    while (foundPos := RegExMatch(output, "s)""([^""]+)""\s*:\s*\{(.*?)\}", match, pos)) {
        objectKey := match1
        objectBody := match2
        instanceName := MuMuJsonStringValue(objectBody, "name")
        if (instanceName != "" && !instanceIndexes.HasKey(instanceName))
            instanceIndexes[instanceName] := objectKey
        pos := foundPos + StrLen(match)
    }

    instanceIndexesLoaded := true
    return instanceIndexes.HasKey(name) ? instanceIndexes[name] : ""
}

MuMuStart(instance) {
    name := getMuMuInstanceIndex(instance)
    return MuMuManagerCommand("control launch -v " . MuMuQuoteArg(name))
}

MuMuShutdownInstance(instance) {
    name := getMuMuInstanceIndex(instance)
    return MuMuManagerCommand("control shutdown -v " . MuMuQuoteArg(name))
}

MuMuRestart(instance) {
    name := getMuMuInstanceIndex(instance)
    return MuMuManagerCommand("control restart -v " . MuMuQuoteArg(name))
}

MuMuSetSetting(instance, key, value) {
    name := getMuMuInstanceIndex(instance)
    return MuMuManagerCommand("setting -v " . MuMuQuoteArg(name) . " -k " . MuMuQuoteArg(key) . " -val " . MuMuQuoteArg(value))
}

MuMuEnableRoot(instance) {
    MuMuSetSetting(instance, "root_permission", "true")
    Sleep, 100
}

MuMuFixRenderStrategy(instance) {
    MuMuSetSetting(instance, "renderer_strategy", "auto")
    Sleep, 100
}

MuMuDisableRoot(instance) {
    MuMuSetSetting(instance, "root_permission", "false")
    Sleep, 100
}

isAutoRender(instance) {
    name := getMuMuInstanceIndex(instance)
    if (name = "")
        return false

    output := MuMuCliCommand("setting -v " . MuMuQuoteArg(name) . " -k renderer_strategy", true)
    rendererStrategy := MuMuJsonStringValue(output, "renderer_strategy")
    if (rendererStrategy = "")
        return false
    if (rendererStrategy = "auto")
        return true

    MsgBox, 36, Graphics Setting, Current graphic settings might mess with image detection. Do you want to correct this setting?
    IfMsgBox, No
        return false

    MuMuFixRenderStrategy(instance)
    MsgBox, 64, Graphics Setting, The graphics setting was corrected. This instance needs to be restarted for the change to take effect.
    return true
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

MuMuCliCommand(args, captureOutput := false) {
    mumuFolder := getMuMuFolder()
    if (mumuFolder = "")
        return ""

    cliPath := mumuFolder . "\nx_main\mumu-cli.exe"
    if (!FileExist(cliPath)) {
        cliPath := mumuFolder . "\shell\mumu-cli.exe"
        if (!FileExist(cliPath))
            return ""
    }

    command := """" . cliPath . """ " . args
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
