#Include *i %A_LineFile%\..\Gdip_All.ahk

ADB_RedactCommand(command) {
    if (RegExMatch(command, "i)^input\s+text\s+"))
        return "input text <redacted>"
    return command
}

ADB_LogTrace(message) {
    LogTrace("[" . A_ScriptName . "] " . message, "ADB.txt")
}

setADBBaseInfo(){
    prof := Prof_Scope(A_ThisFunc)
    ADB_LogTrace("setADBBaseInfo started")
    mumuFolder := getMuMuFolder()
    if(mumuFolder == ""){
        LogError("[" . A_ScriptName . "] MuMu folder could not be resolved while setting ADB base info", "ADB.txt")
        MsgBox, 16, , Can't Find MuMu, try old MuMu installer in Discord #announcements, otherwise double check your folder path setting!`nDefault path is C:\Program Files\Netease
        ExitApp
    }
    adbPath := findAdbPath(mumuFolder)
    ADB_LogTrace("Resolved adbPath=" . adbPath)

    adbPort := findAdbPorts()
    if(!adbPort) {
        LogError("[" . A_ScriptName . "] ADB port could not be resolved", "ADB.txt")
        Msgbox, Invalid port... Check the common issues section in the readme/github guide.
        ExitApp
    }
    ADB_LogTrace("Resolved adbPort=" . adbPort)

    session.set("adbPort", adbPort)
    session.set("adbPath", adbPath)
    session.set("baseTime", 0)
}

KillADBProcesses() {
    prof := Prof_Scope(A_ThisFunc)
    ADB_LogTrace("Killing adb.exe processes")
    ; Use AHK's Process command to close adb.exe
    Process, Close, adb.exe
    ; Fallback to taskkill for robustness
    RunWait, %ComSpec% /c taskkill /IM adb.exe /F /T,, Hide
}

findAdbPorts() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    ADB_LogTrace("findAdbPorts scanning MuMu configs for scriptName=" . session.get("scriptName"))
    ; Initialize variables
    mumuFolder := getMuMuFolder()
    if(mumuFolder == ""){
        LogError("[" . A_ScriptName . "] MuMu folder could not be resolved while finding ADB ports", "ADB.txt")
        MsgBox, 16, , Can't Find MuMu, try old MuMu installer in Discord #announcements, otherwise double check your folder path setting!`nDefault path is C:\Program Files\Netease
        ExitApp
    }

    mumuFolder = %mumuFolder%\vms\*

    ; Loop through all directories in the base folder
    Loop, Files, %mumuFolder%, D  ; D flag to include directories only
    {
        folder := A_LoopFileFullPath
        configFolder := folder "\configs"  ; The config folder inside each directory

        ; Check if config folder exists
        IfExist, %configFolder%
        {
            ; Define paths to vm_config.json and extra_config.json
            vmConfigFile := configFolder "\vm_config.json"
            extraConfigFile := configFolder "\extra_config.json"

            ; Check if vm_config.json exists and read adb host port
            IfExist, %vmConfigFile%
            {
                FileRead, vmConfigContent, %vmConfigFile%
                ; Parse the JSON for adb host port
                RegExMatch(vmConfigContent, """host_port"":\s*""(\d+)""", adbHostPort)
                adbPortValue := adbHostPort1  ; Capture the adb host port value
            }

            ; Check if extra_config.json exists and read playerName
            IfExist, %extraConfigFile%
            {
                FileRead, extraConfigContent, %extraConfigFile%
                ; Parse the JSON for playerName
                RegExMatch(extraConfigContent, """playerName"":\s*""(.*?)""", playerName)
                if(playerName1 = session.get("scriptName")) {
                    ADB_LogTrace("Matched MuMu playerName=" . playerName1 . " adbPort=" . adbPortValue)
                    return adbPortValue
                }
            }
        }
    }
    ADB_LogTrace("findAdbPorts finished without match")
}

RefreshAdbConnectionAfterInstanceRestart(timeoutMs = 30000) {
    prof := Prof_Scope(A_ThisFunc)
    global session

    startTick := A_TickCount
    oldPort := session.get("adbPort")
    lastPort := oldPort

    Loop {
        newPort := findAdbPorts()
        if (newPort) {
            if (newPort != lastPort) {
                LogInfo("[" . A_ScriptName . "] ADB port refreshed after instance restart: " . lastPort . " -> " . newPort, "ADB.txt")
                lastPort := newPort
            }

            session.set("adbPort", newPort)
            ip := "127.0.0.1:" . newPort
            if (oldPort && oldPort != newPort)
                CmdRet(session.get("adbPath") . " disconnect 127.0.0.1:" . oldPort)

            connectionResult := CmdRet(session.get("adbPath") . " connect " . ip)
            if (InStr(connectionResult, "connected to " . ip) || InStr(connectionResult, "already connected to " . ip)) {
                shellResult := CmdRet(session.get("adbPath") . " -s " . ip . " shell echo ready")
                if (InStr(shellResult, "ready")) {
                    session.set("adbShell", "")
                    initializeAdbShell()
                    LogInfo("[" . A_ScriptName . "] ADB reconnected after instance restart on " . ip, "ADB.txt")
                    return true
                }
            }

            LogDebug("[" . A_ScriptName . "] Waiting for ADB after instance restart on " . ip . ". Connection result: " . connectionResult, "ADB.txt")
        } else {
            LogDebug("[" . A_ScriptName . "] Waiting for ADB port after instance restart.", "ADB.txt")
        }

        if ((A_TickCount - startTick) > timeoutMs) {
            LogWarn("[" . A_ScriptName . "] Failed to refresh ADB after instance restart within " . timeoutMs . "ms.", "ADB.txt")
            return false
        }

        Sleep, 2000
    }
}

ConnectAdb() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    MaxRetries := 5
    RetryCount := 1
    connected := false
    ip := "127.0.0.1:" . session.get("adbPort") ; Specify the connection IP:port

    CreateStatusMessage("Connecting to ADB...",,,, false)
    ADB_LogTrace("ConnectAdb starting ip=" . ip . " maxRetries=" . MaxRetries)

    Loop %MaxRetries% {
        ; Attempt to connect using CmdRet
        ADB_LogTrace("ConnectAdb attempt " . RetryCount . "/" . MaxRetries)
        connectionResult := CmdRet(session.get("adbPath") . " connect " . ip)
        ADB_LogTrace("ConnectAdb result=" . Trim(connectionResult))

        ; Check for successful connection in the output
        if InStr(connectionResult, "connected to " . ip) {
            connected := true
            CreateStatusMessage("ADB connected successfully.",,,, false)
            ADB_LogTrace("ConnectAdb connected successfully")
            return true
        } else {
            RetryCount++
            CreateStatusMessage("ADB connection failed.`nRetrying (" . RetryCount . "/" . MaxRetries . ")...",,,, false)
            Sleep, 2000
        }

        if !connected {
            ADB_LogTrace("ConnectAdb disconnect/reconnect cycle starting")
            disconnectionResult := CmdRet(session.get("adbPath") . " disconnect 127.0.0.1:" . session.get("adbPort"))
            connectionResult := CmdRet(session.get("adbPath") . " connect 127.0.0.1:" . session.get("adbPort"))
            LogWarn("[" . A_ScriptName . "] ADB connection failed in ConnectAdb. Bot is reconnecting to ADB.(" . RetryCount . "/" . MaxRetries . ") Connection result: " . connectionResult, "ADB.txt")

            if (RetryCount > MaxRetries) {
                LogError("[" . A_ScriptName . "] ConnectAdb exceeded max retries", "ADB.txt")
                if (Debug)
                    CreateStatusMessage("Failed to connect to ADB after multiple retries. Please check your emulator and port settings.")
                else
                    CreateStatusMessage("Failed to connect to ADB.",,,, false)
                SafeReload("ADB connect failed")
            }
        }
    }
}

DisableBackgroundServices() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    deviceAddress := "127.0.0.1:" . session.get("adbPort")
    ADB_LogTrace("DisableBackgroundServices started deviceAddress=" . deviceAddress)
    commands := []
    ;commands.Push("pm disable-user --user 0 ""com.google.android.gms/.chimera.PersistentIntentOperationService"" 2> /dev/null")
    ;commands.Push("pm disable-user --user 0 ""com.google.android.gms/com.google.android.location.reporting.service.ReportingAndroidService"" 2> /dev/null")
    commands.Push("pm disable-user --user 0 com.mumu.store 2> /dev/null")
    ;commands.Push("pm disable-user --user 0 com.android.chromium 2> /dev/null")
    commands.Push("pm disable-user --user 0 com.android.documentsui 2> /dev/null")
    commands.Push("pm disable-user --user 0 com.android.gallery3d 2> /dev/null")
    commands.Push("pm disable-user --user 0 com.netease.mumu.cloner 2> /dev/null")

    for index, command in commands {
        fullCommand := """" . session.get("adbPath") . """ -s " . deviceAddress . " shell " . command
        ADB_LogTrace("DisableBackgroundServices command=" . command)
        result := CmdRet(fullCommand)
        ADB_LogTrace("DisableBackgroundServices result=" . Trim(result))
    }
}

initializeAdbShell() {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig, session, Debug

    RetryCount := 1
    MaxRetries := 5
    BackoffTime := 1000  ; Initial backoff time in milliseconds
    MaxBackoff := 5000   ; Prevent excessive waiting
    ADB_LogTrace("initializeAdbShell starting maxRetries=" . MaxRetries)

    Loop {
        try {
            if (!session.get("adbShell") || session.get("adbShell").Status != 0) {
                ADB_LogTrace("initializeAdbShell creating new shell")
                session.set("adbShell", "")  ; Reset before reattempting

                ; Validate adbPath and adbPort
                if (!FileExist(session.get("adbPath"))) {
                    throw Exception("ADB path is invalid: " . session.get("adbPath"))
                }
                if (session.get("adbPort") < 0 || session.get("adbPort") > 65535) {
                    throw Exception("ADB port is invalid: " . session.get("adbPort"))
                }

                ; Attempt to start adb shell
                ADB_LogTrace("initializeAdbShell exec adb shell port=" . session.get("adbPort"))
                session.set("adbShell", ComObjCreate("WScript.Shell").Exec(session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort") . " shell"))

                ; Ensure adbShell is running before sending 'su'
                Sleep, 500
                if (session.get("adbShell").Status != 0) {
                    RetryCount++
                    disconnectionResult := CmdRet(session.get("adbPath") . " disconnect 127.0.0.1:" . session.get("adbPort"))
                    connectionResult := CmdRet(session.get("adbPath") . " connect 127.0.0.1:" . session.get("adbPort"))
                    LogWarn("[" . A_ScriptName . "] ADB connection failed in initializeAdbShell. Bot is reconnecting to ADB.(" . RetryCount . "/" . MaxRetries . ") Connection result: " . connectionResult, "ADB.txt")

                    if (RetryCount > MaxRetries) {
                        throw Exception("Failed to start ADB shell.")
                    }
                    else
                        continue
                }

                try {
                    RetryCount++
                    ADB_LogTrace("initializeAdbShell requesting su")
                    session.get("adbShell").StdIn.WriteLine("su")
                } catch e2 {
                    if (RetryCount > MaxRetries) {
                        throw Exception("Failed to elevate shell: " . (IsObject(e2) ? e2.Message : e2))
                    }
                }
            }

            ; If adbShell is running, break loop
            if (session.get("adbShell").Status = 0) {
                ADB_LogTrace("initializeAdbShell ready pid=" . session.get("adbShell").ProcessID)
                break
            }
        } catch e {
            errorMessage := IsObject(e) ? e.Message : e
            LogError("[" . A_ScriptName . "] ADB Shell Error: " . errorMessage, "ADB.txt")

            if (RetryCount >= MaxRetries) {
                if (Debug)
                    CreateStatusMessage("Failed to connect to shell after multiple attempts: " . errorMessage)
                else
                    CreateStatusMessage("Failed to connect to shell. Retrying...",,,, false)

                RetryCount := 1  ; Reset retry count for next round
            }
        }

        Sleep, BackoffTime
        BackoffTime := Min(BackoffTime + 1000, MaxBackoff)  ; Limit backoff time
        ADB_LogTrace("initializeAdbShell backing off nextDelay=" . BackoffTime)
    }
}

waitUntilActivatePTCGPApp(){
    prof := Prof_Scope(A_ThisFunc)
    global session, Debug

    session.set("baseTime", A_TickCount)
    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    ADB_LogTrace("waitUntilActivatePTCGPApp started")
    Loop, {
        result := CmdRet(adbCommand . " shell dumpsys window | grep -E 'mCurrentFocus'")
        ADB_LogTrace("waitUntilActivatePTCGPApp focus=" . Trim(result))
        if (InStr(result, "jp.pokemon.pokemontcgp"))
            break

        Sleep, 200
        if((A_TickCount - session.get("baseTime")) > 5000){
            LogWarn("[" . A_ScriptName . "] waitUntilActivatePTCGPApp timed out", "ADB.txt")
            return false
        }
    }

    ADB_LogTrace("waitUntilActivatePTCGPApp detected active app")
    return true
}

isPTCGPAppFocused() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    result := CmdRet(adbCommand . " shell dumpsys window | grep -E 'mCurrentFocus'")
    ADB_LogTrace("isPTCGPAppFocused focus=" . Trim(result))
    return InStr(result, "jp.pokemon.pokemontcgp")
}

doesMissionUserPrefsExist() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    result := Trim(CmdRet(adbCommand . " shell su -c '""test -f /data/data/jp.pokemon.pokemontcgp/files/UserPreferences/v1/MissionUserPrefs && echo 1 || echo 0""'"), "`r`n`t ")
    ADB_LogTrace("doesMissionUserPrefsExist result=" . result)
    return (result = "1")
}

startPTCGPApp() {
    prof := Prof_Scope(A_ThisFunc)
    ADB_LogTrace("startPTCGPApp started")
    retryCount := 0
    Loop {
        appTerminated := isTerminatePTCGPApp()
        if(!appTerminated && isPTCGPAppFocused()) {
            ADB_LogTrace("startPTCGPApp finished retryCount=" . retryCount)
            return true
        }

        if(appTerminated)
            adbWriteRaw("rm -f /data/data/jp.pokemon.pokemontcgp/files/UserPreferences/v1/MissionUserPrefs")

        ADB_LogTrace("startPTCGPApp home/outside-app state detected; starting app")
        adbWriteRaw("am start -W -n jp.pokemon.pokemontcgp/com.unity3d.player.UnityPlayerActivity -f 0x10018000")
        DelayH(100)

        if(waitUntilActivatePTCGPApp()) {
            ADB_LogTrace("startPTCGPApp finished retryCount=" . retryCount)
            return true
        }

        if(++retryCount >= 3) {
            LogWarn("[" . A_ScriptName . "] startPTCGPApp failed to activate after " . retryCount . " attempts", "ADB.txt")
            ADB_LogTrace("startPTCGPApp failed retryCount=" . retryCount)
            return false
        }
    }
}

startPTCGPApp_ApplyMetadataLanguage(loadFile) {
    prof := Prof_Scope(A_ThisFunc)
    global session

    if (!IsObject(session) || !session.get("injectMethod") || session.get("accountFileName") = "")
        return false

    accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), loadFile)
    language := Trim(accountMeta["language"])
    if (language = "")
        return true

    if (!RegExMatch(language, "i)^[a-z][a-z0-9_-]{0,15}$")) {
        LogWarn("startPTCGPApp ignored unexpected metadata language value: " . language)
        return false
    }

    if (IsFunc("EnsurePTCGPBHelperInstalled")) {
        ensureHelper := Func("EnsurePTCGPBHelperInstalled")
        if (!ensureHelper.Call()) {
            LogWarn("startPTCGPApp could not install ptcgpb helper before setting language")
            return false
        }
    }

    LogTrace("Setting in-game language from metadata: " . language, "ADB.txt")
    adbWriteRaw("/data/ptcgp/ptcgpb lang " . language)
    return true
}

closePTCGPApp(){
    prof := Prof_Scope(A_ThisFunc)
    adbWriteRaw("am force-stop jp.pokemon.pokemontcgp")
    adbWriteRaw("rm -f /data/data/jp.pokemon.pokemontcgp/files/UserPreferences/v1/MissionUserPrefs")
    DelayH(100)
}

isCurrentScreenHome(){
    prof := Prof_Scope(A_ThisFunc)
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    result := CmdRet(adbCommand . " shell dumpsys window | grep -E 'mCurrentFocus'")
    ADB_LogTrace("isCurrentScreenHome focus=" . Trim(result))
    if (!InStr(result, "jp.pokemon.pokemontcgp")){
        Sleep, 250
        return true
    }
    else
        return false
}

isTerminatePTCGPAppByADBShell() {
    prof := Prof_Scope(A_ThisFunc)
    static cachedResult := ""
    static cachedAt := 0
    cacheTtlMs := 5000

    if (cachedResult != "" && (A_TickCount - cachedAt) < cacheTtlMs) {
        ADB_LogTrace("isTerminatePTCGPAppByADBShell cachedResult=" . cachedResult)
        return cachedResult
    }

    result := adbWriteRaw("pidof jp.pokemon.pokemontcgp", true)
    ADB_LogTrace("isTerminatePTCGPAppByADBShell pidResult=" . Trim(result))
    if (RegExMatch(result, "\d+")) {
        cachedResult := false
    }
    else
        cachedResult := true

    cachedAt := A_TickCount
    return cachedResult
}

isTerminatePTCGPHelperApp(){
    prof := Prof_Scope(A_ThisFunc)
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    result := CmdRet(adbCommand . " shell pidof ptcgpb")
    ADB_LogTrace("isTerminatePTCGPHelperApp pidResult=" . Trim(result))
    if (RegExMatch(result, "\d+")) {
        return false
    }
    else
        return true
}

isTerminatePTCGPApp() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    result := CmdRet(adbCommand . " shell pidof jp.pokemon.pokemontcgp")
    ADB_LogTrace("isTerminatePTCGPApp pidResult=" . Trim(result))
    if (RegExMatch(result, "\d+")) {
        return false
    }
    else
        return true
}

clearMissionCache() {
    prof := Prof_Scope(A_ThisFunc)
    ADB_LogTrace("clearMissionCache")
    adbWriteRaw("rm -f /data/data/jp.pokemon.pokemontcgp/files/UserPreferences/v1/MissionUserPrefs")
    Sleep, 250
}

adbEnsureShell() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    pid := session.get("adbShell").ProcessID
    Process, Exist, %pid%

    if (!ErrorLevel || session.get("adbShell").Status != 0) {
        ADB_LogTrace("adbEnsureShell detected missing/dead shell; reinitializing")
        initializeAdbShell()
    }
}

adbWriteRaw(command, isReturnning := false, timeoutMs := 60000) {
    prof := Prof_Scope(A_ThisFunc)
    global session
    retries := 0
    MaxRetries := 3
    loopCount := 0

    Loop {
        result := ""
        line := ""
        startTime := A_TickCount
        try {
            ADB_LogTrace("adbWriteRaw send returning=" . (isReturnning ? 1 : 0) . " timeoutMs=" . timeoutMs . " command=" . ADB_RedactCommand(command))
            session.get("adbShell").StdIn.WriteLine(command . ";echo done;")
            Loop {
                pid := session.get("adbShell").ProcessID
                Process, Exist, %pid%

                if (!ErrorLevel || session.get("adbShell").Status != 0) {
                    ADB_LogTrace("adbWriteRaw detected dead shell while waiting for command")
                    initializeAdbShell()
                    break
                }

                if (timeoutMs > 0 && (A_TickCount - startTime) > timeoutMs) {
                    ADB_LogTrace("adbWriteRaw timeout elapsedMs=" . (A_TickCount - startTime) . " command=" . ADB_RedactCommand(command))
                    try {
                        session.get("adbShell").Terminate()
                    } catch e2 {
                    }
                    session.set("adbShell", "")
                    initializeAdbShell()
                    return isReturnning ? result : false
                }

                if (session.get("adbShell").StdOut.AtEndOfStream) {
                    Sleep, 50
                    continue
                }

                ch := session.get("adbShell").StdOut.Read(1)
                if (ch = "`r")
                    continue

                if (ch != "`n") {
                    line .= ch
                    continue
                }

                if (line = "done"){
                    if(isReturnning) {
                        ADB_LogTrace("adbWriteRaw done outputBytes=" . StrLen(result))
                        return result
                    }
                    else {
                        ADB_LogTrace("adbWriteRaw done")
                        return true
                    }
                }
                else if(isReturnning)
                    result .= line . "`n"

                line := ""

                Sleep, 50
            }

            if(loopCount > 5){
                throw Exception("[adbWriteRaw] Command was attempted more than 5 times but failed.")
                loopCount := 0
            }
            else
                loopCount++

        } catch e {
            errorMessage := IsObject(e) ? e.Message : e
            retries++
            LogWarn("[" . A_ScriptName . "] ADB write error(" . retries . "/" . MaxRetries . ") Command: " . ADB_RedactCommand(command) . ", Error: " . errorMessage, "ADB.txt")
            session.set("adbShell", "")
            if (retries >= MaxRetries){
                LogInfo("[" . A_ScriptName . "] Reconnect to ADB Server. command: " . ADB_RedactCommand(command), "ADB.txt")
                adbEnsureShell()
            }
            Sleep, 300
        }
    }
}

waitadb(){
    return
}

adbClick(X, Y) {
    prof := Prof_Scope(A_ThisFunc)
    static clickCommands := Object()
    metrics := GetAdbClickMetrics()
    key := X "|" Y "|" metrics.convX "|" metrics.convY "|" metrics.offset

    if (!clickCommands.HasKey(key)) {
        clickCommands[key] := Format("input tap {} {}"
            , Round(X * metrics.convX)
            , Round((Y + metrics.offset) * metrics.convY))
    }
    ADB_LogTrace("adbClick logical=(" . X . "," . Y . ") command=" . clickCommands[key])
    adbWriteRaw(clickCommands[key])
}

adbInput(name) {
    prof := Prof_Scope(A_ThisFunc)
    ADB_LogTrace("adbInput chars=" . StrLen(name))
    adbWriteRaw("input text " . name)
    waitadb()
}

adbInputEvent(event) {
    prof := Prof_Scope(A_ThisFunc)
    ADB_LogTrace("adbInputEvent event=" . event)
    if InStr(event, " ") {
        ; If the event uses a space, we use keycombination
        adbWriteRaw("input keycombination " . event)
    } else {
        ; It's a single key event (e.g., "67")
        adbWriteRaw("input keyevent " . event)
    }
    waitadb()
}

; Simulates a swipe gesture on an Android device, swiping from one X/Y-coordinate to another.
adbSwipe(params) {
    prof := Prof_Scope(A_ThisFunc)
    ADB_LogTrace("adbSwipe params=" . params)
    adbWriteRaw("input swipe " . params)
    waitadb()
}

; Simulates a touch gesture on an Android device to scroll in a controlled way.
; Not currently supported.
adbGesture(params) {
    prof := Prof_Scope(A_ThisFunc)
    ; Example params (a 2-second hold-drag from a lower to an upper Y-coordinate): 0 2000 138 380 138 90 138 90
    ADB_LogTrace("adbGesture params=" . params)
    adbWriteRaw("input touchscreen gesture " . params)
    waitadb()
}

; Takes a screenshot of an Android device using ADB and saves it to a file.
adbTakeScreenshot(outputFile) {
    prof := Prof_Scope(A_ThisFunc)
    ; Percroy Optimization
    global session

    static pTokenLocal := 0
    if (!pTokenLocal) {
        pTokenLocal := Gdip_Startup()
    }

    deviceAddress := "127.0.0.1:" . session.get("adbPort")
    baseCommand := """" . session.get("adbPath") . """ -s " . deviceAddress
    ADB_LogTrace("adbTakeScreenshot outputFile=" . outputFile)

    hwnd := getMuMuHwnd(session.get("winTitle"))
    if (!hwnd) {
        command := baseCommand . " exec-out screencap -p > """ .  outputFile . """"
        ADB_LogTrace("adbTakeScreenshot using exec-out fallback because hwnd missing")
        RunWait, %ComSpec% /c "%command%", , Hide
        return
    }

    pBitmap := Gdip_BitmapFromHWND(hwnd)

    if (!pBitmap || pBitmap = "") {
        deviceAddress := "127.0.0.1:" . session.get("adbPort")
        command := baseCommand . " exec-out screencap -p > """ .  outputFile . """"
        ADB_LogTrace("adbTakeScreenshot using exec-out fallback because bitmap capture failed")
        RunWait, %ComSpec% /c "%command%", , Hide
        return
    }

    SplitPath, outputFile, , outputDir
    if (outputDir && !FileExist(outputDir)) {
        FileCreateDir, %outputDir%
    }

    result := Gdip_SaveBitmapToFile(pBitmap, outputFile)
    ADB_LogTrace("adbTakeScreenshot GDI save result=" . result)

    Gdip_DisposeImage(pBitmap)

    if (!result || result = -1) {
        deviceAddress := "127.0.0.1:" . session.get("adbPort")
        command := baseCommand . " exec-out screencap -p > """ .  outputFile . """"
        ADB_LogTrace("adbTakeScreenshot using exec-out fallback because save failed")
        RunWait, %ComSpec% /c "%command%", , Hide
        return
    }
}
