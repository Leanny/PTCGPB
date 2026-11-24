#Include *i %A_LineFile%\..\Gdip_All.ahk

#Include %A_LineFile%\..\PTCGPHelper.ahk

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
    adbPort := findAdbPorts()
    if(!adbPort) {
        LogError("[" . A_ScriptName . "] ADB port could not be resolved", "ADB.txt")
        Msgbox, Invalid port... Check the common issues section in the readme/github guide.
        ExitApp
    }
    ADB_LogTrace("Resolved adbPort=" . adbPort)

    adbPath := findAdbPath(mumuFolder, session.get("muMuAndroid15"))
    ADB_LogTrace("Resolved adbPath=" . adbPath)

    session.set("adbPort", adbPort)
    session.set("adbPath", adbPath)
    session.set("baseTime", 0)
}

; Kills persistent "adb -s <host>:<port> shell" processes started from MuMu's
; adb whose AutoHotkey parent is gone. These are left behind when a bot script is
; terminated without cleanup. Shells of running scripts, the adb server, short
; lived adb commands and adb.exe from other tools are left alone.
KillOrphanedAdbShells() {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig

    mumuFolder := MuMuResolveFolder(botConfig.get("folderPath"))
    if (mumuFolder = "") {
        LogWarn("Orphaned adb shell cleanup skipped: MuMu folder could not be resolved", "ADB.txt")
        return 0
    }

    killed := 0
    try {
        wmi := ComObjGet("winmgmts:")
        processes := {}
        for process in wmi.ExecQuery("Select ProcessId, Name, CreationDate from Win32_Process")
            processes[process.ProcessId + 0] := {name: process.Name, created: process.CreationDate}

        for process in wmi.ExecQuery("Select ProcessId, ParentProcessId, CommandLine, ExecutablePath, CreationDate from Win32_Process Where Name = 'adb.exe'") {
            exePath := process.ExecutablePath
            if (exePath = "" || SubStr(exePath, 1, StrLen(mumuFolder) + 1) != mumuFolder . "\")
                continue
            if (!RegExMatch(process.CommandLine, "i)\s-s\s+[\d.]+:\d+\s+shell\s*$"))
                continue

            ; The parent counts as alive only if it is an AutoHotkey process that
            ; started before the shell, so a reused PID does not keep an orphan alive.
            parent := processes[process.ParentProcessId + 0]
            if (IsObject(parent) && RegExMatch(parent.name, "i)^AutoHotkey.*\.exe$") && parent.created <= process.CreationDate)
                continue

            pid := process.ProcessId + 0
            Process, Close, %pid%
            if (ErrorLevel) {
                killed++
                LogInfo("Killed orphaned adb shell PID " . pid . " (parent PID " . process.ParentProcessId . "): " . process.CommandLine, "ADB.txt")
            } else {
                LogWarn("Could not kill orphaned adb shell PID " . pid, "ADB.txt")
            }
        }
    } catch e {
        LogError("Orphaned adb shell cleanup failed: " . (IsObject(e) ? e.Message : e), "ADB.txt")
    }
    return killed
}

; Puts the persistent adb shell into a job object that Windows kills when this
; script exits for any reason (ExitApp, Reload, Process Close, crash), so the
; shell cannot outlive its bot script. SILENT_BREAKAWAY_OK keeps processes the
; shell spawns, such as an adb server it starts, out of the job.
ADB_AssignToShellJob(pid) {
    static hJob := 0
    static JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK := 0x1000, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE := 0x2000
        , JobObjectExtendedLimitInformation := 9, PROCESS_TERMINATE := 0x0001, PROCESS_SET_QUOTA := 0x0100

    if (!hJob) {
        hJob := DllCall("CreateJobObject", "Ptr", 0, "Ptr", 0, "Ptr")
        if (!hJob) {
            LogWarn("[" . A_ScriptName . "] CreateJobObject failed; error=" . A_LastError, "ADB.txt")
            return false
        }
        ; JOBOBJECT_EXTENDED_LIMIT_INFORMATION; LimitFlags is at offset 16 on both architectures.
        infoSize := (A_PtrSize = 8) ? 144 : 112
        VarSetCapacity(info, infoSize, 0)
        NumPut(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK, info, 16, "UInt")
        if (!DllCall("SetInformationJobObject", "Ptr", hJob, "Int", JobObjectExtendedLimitInformation, "Ptr", &info, "UInt", infoSize)) {
            LogWarn("[" . A_ScriptName . "] SetInformationJobObject failed; error=" . A_LastError, "ADB.txt")
            DllCall("CloseHandle", "Ptr", hJob)
            hJob := 0
            return false
        }
        ; The job handle is intentionally never closed; closing it happens on exit.
    }

    hProcess := DllCall("OpenProcess", "UInt", PROCESS_TERMINATE | PROCESS_SET_QUOTA, "Int", false, "UInt", pid, "Ptr")
    if (!hProcess) {
        LogWarn("[" . A_ScriptName . "] OpenProcess failed for adb shell PID " . pid . "; error=" . A_LastError, "ADB.txt")
        return false
    }
    assigned := DllCall("AssignProcessToJobObject", "Ptr", hJob, "Ptr", hProcess)
    if (!assigned)
        LogWarn("[" . A_ScriptName . "] AssignProcessToJobObject failed for adb shell PID " . pid . "; error=" . A_LastError, "ADB.txt")
    DllCall("CloseHandle", "Ptr", hProcess)
    return assigned
}

; Returns the "host:port" adb serial of this instance (127.0.0.1 unless MuMu uses bridge mode).
AdbAddress() {
    global session
    host := session.get("adbHost")
    if (host = "")
        host := "127.0.0.1"
    return host . ":" . session.get("adbPort")
}

; In host-bridge mode MuMu exposes adb on the bridged IP instead of a forwarded localhost port.
; MuMuManager reports the real endpoint for a running instance; returns true and sets host/port if found.
ResolveMuMuAdbEndpoint(vmFolder, playerName, ByRef host, ByRef port) {
    ; The VM folder ends with its MuMu index (e.g. MuMuPlayerGlobal-12.0-5); fall back to a name lookup.
    index := RegExMatch(vmFolder, "-(\d+)$", folderMatch) ? folderMatch1 : MuMuGetInstanceIndex(playerName)
    if (index = "")
        return false
    output := MuMuManagerCommand("info -v " . MuMuQuoteArg(index), true)
    if (!RegExMatch(output, """adb_host_ip""\s*:\s*""([^""]+)""", ipMatch)
        || !RegExMatch(output, """adb_port""\s*:\s*""?(\d+)""?", portMatch))
        return false
    host := ipMatch1
    ; MuMu keeps reporting the NAT-forwarded port in bridge mode, but adb listens on the default 5555 there.
    port := (host = "127.0.0.1" || host = "localhost") ? portMatch1 : 5555
    return true
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
                    ADB_LogTrace("Matched MuMu playerName=" . playerName1 . " adbPort=" . adbPortValue . " android15=" . (InStr(folder, "MuMuPlayerGlobal-15.0") ? 1 : 0))
                    session.set("muMuAndroid15", InStr(folder, "MuMuPlayerGlobal-15.0") ? 1 : 0)
                    adbHostValue := "127.0.0.1"
                    if (ResolveMuMuAdbEndpoint(folder, playerName1, bridgeHost, bridgePort)) {
                        adbHostValue := bridgeHost
                        adbPortValue := bridgePort
                        ADB_LogTrace("MuMu reports adb endpoint " . adbHostValue . ":" . adbPortValue)
                    }
                    session.set("adbHost", adbHostValue)
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
    oldAddress := AdbAddress()
    lastPort := oldPort

    Loop {
        newPort := findAdbPorts()
        if (newPort) {
            if (newPort != lastPort) {
                LogInfo("[" . A_ScriptName . "] ADB port refreshed after instance restart: " . lastPort . " -> " . newPort, "ADB.txt")
                lastPort := newPort
            }

            session.set("adbPort", newPort)
            ip := AdbAddress()
            if (oldPort && oldAddress != ip)
                CmdRet(session.get("adbPath") . " disconnect " . oldAddress)

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
    ip := AdbAddress() ; Specify the connection IP:port

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
            disconnectionResult := CmdRet(session.get("adbPath") . " disconnect " . AdbAddress())
            connectionResult := CmdRet(session.get("adbPath") . " connect " . AdbAddress())
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

    deviceAddress := AdbAddress()
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
                oldShell := session.get("adbShell")
                if (IsObject(oldShell)) {
                    try {
                        oldShell.Terminate()
                    } catch {
                    }
                }
                session.set("adbShell", "")  ; Reset before reattempting
                session.set("adbPendingAcks", 0)  ; markers of the old shell are gone

                ; Validate adbPath and adbPort
                if (!FileExist(session.get("adbPath"))) {
                    throw Exception("ADB path is invalid: " . session.get("adbPath"))
                }
                if (session.get("adbPort") < 0 || session.get("adbPort") > 65535) {
                    throw Exception("ADB port is invalid: " . session.get("adbPort"))
                }

                ; check graphics settings
                isAutoRender(session.get("scriptName"))

                ; disable root and restart as root shell
                MuMuDisableRoot(session.get("scriptName"))
                ADB_LogTrace("initializeAdbShell adb shell port=" . session.get("adbPort"))
                RunWait, % session.get("adbPath") . " -s " . AdbAddress() . " root", , Hide

                ; Attempt to start adb shell
                ADB_LogTrace("initializeAdbShell exec adb shell port=" . session.get("adbPort"))
                session.set("adbShell", ComObjCreate("WScript.Shell").Exec(session.get("adbPath") . " -s " . AdbAddress() . " shell"))
                ADB_AssignToShellJob(session.get("adbShell").ProcessID)

                ; Ensure adbShell is running before sending 'su'
                Sleep, 500
                if (session.get("adbShell").Status != 0) {
                    RetryCount++
                    disconnectionResult := CmdRet(session.get("adbPath") . " disconnect " . AdbAddress())
                    connectionResult := CmdRet(session.get("adbPath") . " connect " . AdbAddress())
                    LogWarn("[" . A_ScriptName . "] ADB connection failed in initializeAdbShell. Bot is reconnecting to ADB.(" . RetryCount . "/" . MaxRetries . ") Connection result: " . connectionResult, "ADB.txt")

                    if (RetryCount > MaxRetries) {
                        throw Exception("Failed to start ADB shell.")
                    }
                    else
                        continue
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
    adbCommand := session.get("adbPath") . " -s " . AdbAddress()
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

doesMissionUserPrefsExist() {
    prof := Prof_Scope(A_ThisFunc)

    result := Trim(adbWriteRaw("if [ -f /data/data/jp.pokemon.pokemontcgp/files/UserPreferences/v1/MissionUserPrefs ]; then echo 1; else echo 0; fi", true), "`r`n`t ")
    ADB_LogTrace("doesMissionUserPrefsExist result=" . result)
    return (result = "1")
}

clearPTCGPAppLogcat() {
    prof := Prof_Scope(A_ThisFunc)

    ADB_LogTrace("clearPTCGPAppLogcat")
    return adbWriteRaw("logcat -c", false, 10000)
}

getPTCGPAppPid() {
    prof := Prof_Scope(A_ThisFunc)

    result := Trim(adbWriteRaw("pidof jp.pokemon.pokemontcgp", true, 10000), "`r`n`t ")
    if (RegExMatch(result, "(\d+)", match))
        return match1

    return ""
}

; Device-side filter for the Unity "CRASH" error tag. Only matching lines cross the adb pipe,
; instead of dumping the whole logcat buffer to a file and grepping it in a second round trip.
PTCGPAppCrashLogcatCommand() {
    return "logcat -d -v threadtime -s CRASH:E 2>/dev/null"
}

readPTCGPAppCrashLogcat() {
    prof := Prof_Scope(A_ThisFunc)
    return adbWriteRaw(PTCGPAppCrashLogcatCommand(), true, 10000)
}

; Returns the first crash line logged by pid, or "" when there is none.
findPTCGPAppCrashLine(logcat, pid) {
    if (pid = "")
        return ""

    Loop, Parse, logcat, `n, `r
    {
        if (RegExMatch(A_LoopField, "^\d\d-\d\d\s+\d\d:\d\d:\d\d\.\d+\s+" . pid . "\s+\d+\s+E\s+CRASH\s*:"))
            return A_LoopField
    }
    return ""
}

; The pid the crash log is matched against: the one recorded at app start, else the current one.
resolvePTCGPAppPid(currentPid := "") {
    global session

    pid := ""
    if (IsObject(session))
        pid := session.get("ptcgpAppPid")

    if (!RegExMatch(pid, "^\d+$")) {
        pid := (currentPid != "") ? currentPid : getPTCGPAppPid()
        if (IsObject(session) && pid != "")
            session.set("ptcgpAppPid", pid)
    }
    return pid
}

hasPTCGPAppCrashInLogcat() {
    prof := Prof_Scope(A_ThisFunc)

    pid := resolvePTCGPAppPid()
    if (pid = "") {
        ADB_LogTrace("hasPTCGPAppCrashInLogcat skipped; no PTCGPApp pid")
        return false
    }

    line := findPTCGPAppCrashLine(readPTCGPAppCrashLogcat(), pid)
    if (line != "") {
        LogWarn("[" . A_ScriptName . "] PTCGPApp crash detected in logcat: " . line, "ADB.txt")
        return true
    }

    ADB_LogTrace("hasPTCGPAppCrashInLogcat no crash pid=" . pid)
    return false
}

isCrashPTCGPApp() {
    prof := Prof_Scope(A_ThisFunc)
    return hasPTCGPAppCrashInLogcat()
}

; If for any reason any file has the wrong owner, the app crashes
FixPTCGPAppUserPreferencesOwnership() {
    prof := Prof_Scope(A_ThisFunc)

    appDir := "/data/data/jp.pokemon.pokemontcgp"
    prefsDir := appDir . "/files/UserPreferences"

    wrongOwner := Trim(adbWriteRaw("find " . prefsDir . " ! -user $(stat -c %u " . appDir . ") 2>/dev/null", true), "`r`n`t ")
    if (wrongOwner = "") {
        ADB_LogTrace("FixPTCGPAppUserPreferencesOwnership nothing to fix")
        return
    }

    LogWarn("[" . A_ScriptName . "] Fixing ownership of files/UserPreferences, not owned by the app: " . StrReplace(StrReplace(wrongOwner, "`r"), "`n", ", "), "ADB.txt")
    adbWriteRaw("find " . prefsDir . " -exec chown $(stat -c %u:%g " . appDir . ") {} +`; chmod -R u+rwX " . prefsDir . "`; chcon -R $(ls -Zd " . appDir . "/files | cut -d' ' -f1) " . prefsDir)
}

startPTCGPApp(isMain := false) {
    prof := Prof_Scope(A_ThisFunc)
    global session

    ADB_LogTrace("startPTCGPApp started")
    clearPTCGPAppLogcat()
    if (IsObject(session))
        session.set("ptcgpAppPid", "")

    retryCount := 0
    Loop {
        if(isTerminatePTCGPApp()) {
            ADB_LogTrace("startPTCGPApp home/outside-app state detected; starting app")
            if (!isMain)
                StartCleanup()
            FixPTCGPAppUserPreferencesOwnership()
            adbWriteRaw("am start -W -n jp.pokemon.pokemontcgp/com.unity3d.player.UnityPlayerActivity -f 0x10018000")
            DelayH(100)
        }
        if(waitUntilActivatePTCGPApp())
            break
        if(++retryCount >= 3)
            break
    }
    appPid := getPTCGPAppPid()
    if (IsObject(session)) {
        session.set("ptcgpAppPid", appPid)
        ; a fresh app start resets the speed mod to 1x
        session.set("currentGameSpeed", 0)
    }
    ADB_LogTrace("startPTCGPApp pid=" . appPid)
    ADB_LogTrace("startPTCGPApp finished retryCount=" . retryCount)
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

; Allows the game (Mod Menu apk) to draw over other apps, like the Instance Manager does
; after installing the apk. Returns true if the permission is enabled afterwards.
adbGrantOverlayPermission(package := "jp.pokemon.pokemontcgp") {
    prof := Prof_Scope(A_ThisFunc)
    check := "cmd appops get " . package . " SYSTEM_ALERT_WINDOW"
    if (InStr(adbWriteRaw(check, true), "SYSTEM_ALERT_WINDOW: allow"))
        return true

    adbWriteRaw("cmd appops set " . package . " SYSTEM_ALERT_WINDOW allow")
    output := adbWriteRaw(check, true)
    if (!InStr(output, "SYSTEM_ALERT_WINDOW: allow")) {
        LogWarn("Could not enable the overlay permission for " . package . ": " . Trim(output, "`r`n`t "), "ADB.txt")
        return false
    }
    LogInfo("Enabled the overlay permission for " . package, "ADB.txt")
    return true
}

; Denies the camera permission of the game (user-fixed) so Android never shows its permission dialog.
; Resulting state: granted=false, flags=USER_SET|USER_FIXED, appops CAMERA=ignore.
adbDenyCameraPermission(package := "jp.pokemon.pokemontcgp") {
    prof := Prof_Scope(A_ThisFunc)
    check := "dumpsys package " . package . " | grep 'permission.CAMERA:'; cmd appops get " . package . " CAMERA | head -1"
    if (adbCameraDenied(adbWriteRaw(check, true)))
        return true

    adbWriteRaw("pm revoke " . package . " android.permission.CAMERA")
    adbWriteRaw("pm set-permission-flags " . package . " android.permission.CAMERA user-set user-fixed")
    adbWriteRaw("cmd appops set --uid " . package . " CAMERA ignore")
    output := adbWriteRaw(check, true)

    ; Android 12 has no "pm set-permission-flags", so the flag has to be written to the permission file
    if (!adbCameraDenied(output) && adbSetCameraFixedViaFile(package)) {
        adbWriteRaw("cmd appops set --uid " . package . " CAMERA ignore")
        output := adbWriteRaw(check, true)
    }

    if (!adbCameraDenied(output)) {
        LogWarn("Could not deny the camera permission for " . package . ": " . Trim(output, "`r`n`t "), "ADB.txt")
        return false
    }
    LogInfo("Denied the camera permission for " . package, "ADB.txt")
    return true
}

; Android 12 fallback: set USER_FIXED (0x2) in runtime-permissions.xml (flags are hex, 303 = USER_SET|USER_FIXED|USER_SENSITIVE_*)
; and restart the framework (zygote) so Android reloads the file. This drops adb root, so the shell is re-initialized afterwards.
adbSetCameraFixedViaFile(package) {
    prof := Prof_Scope(A_ThisFunc)
    global session
    file := "/data/misc_de/0/apexdata/com.android.permission/runtime-permissions.xml"
    block := "sed -n '/package name=." . package . "./,/<.package>/p' " . file . " | grep 'permission.CAMERA. granted'"

    ; "pm revoke" makes Android persist an entry for the package, which can take a moment
    entry := ""
    Loop, 10 {
        entry := adbWriteRaw(block, true)
        if (InStr(entry, "android.permission.CAMERA"))
            break
        Sleep, 500
    }
    if (!InStr(entry, "android.permission.CAMERA")) {
        LogWarn("Camera permission entry for " . package . " not found in " . file, "ADB.txt")
        return false
    }

    adbWriteRaw("am force-stop " . package)
    adbWriteRaw("sed -i '/package name=." . package . "./,/<.package>/{/permission.CAMERA. granted/s/flags=.[0-9a-f]*./flags=""303""/}' " . file)
    if (!InStr(adbWriteRaw(block, true), "flags=""303"""))
        return false

    LogInfo("Restarting Android framework to apply the camera permission flags for " . package, "ADB.txt")
    try {
        session.get("adbShell").StdIn.WriteLine("setprop ctl.restart zygote;echo done;")
    } catch {
    }
    Sleep, 3000
    try {
        session.get("adbShell").Terminate()
    } catch {
    }
    session.set("adbShell", "")

    ; The restart drops adb root. Reconnect and only continue once the shell is root and Android has booted.
    Loop, 30 {
        initializeAdbShell()
        state := adbWriteRaw("getprop sys.boot_completed; id", true)
        if (InStr(state, "uid=0") && RegExMatch(state, "m)^1\s*$"))
            return true

        try {
            session.get("adbShell").Terminate()
        } catch {
        }
        session.set("adbShell", "")
        Sleep, 2000
    }
    LogWarn("Could not get a root shell back after restarting the Android framework", "ADB.txt")
    return false
}

adbCameraDenied(output) {
    return InStr(output, "granted=false") && InStr(output, "USER_FIXED") && InStr(output, "Uid mode: CAMERA: ignore")
}

isPTCGPAppInFocus() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    adbCommand := session.get("adbPath") . " -s " . AdbAddress()
    result := CmdRet(adbCommand . " shell dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp'")
    if (result = "")
        result := CmdRet(adbCommand . " shell dumpsys window | grep -E 'mCurrentFocus'")
    ADB_LogTrace("isPTCGPAppInFocus focus=" . Trim(result))
    return InStr(result, "jp.pokemon.pokemontcgp")
}

isCurrentScreenHome(){
    prof := Prof_Scope(A_ThisFunc)
    if (!isPTCGPAppInFocus()) {
        Sleep, 250
        return true
    }
    return false
}

bringPTCGPAppToForeground() {
    prof := Prof_Scope(A_ThisFunc)
    ADB_LogTrace("bringPTCGPAppToForeground")
    adbWriteRaw("am start -n jp.pokemon.pokemontcgp/com.unity3d.player.UnityPlayerActivity -f 0x20000000")
    DelayH(100)
    waitUntilActivatePTCGPApp()
}

; Instance scripts define restartGameInstance later in the same host script.
; PTCGPB.ahk and other thin hosts only include ADB.ahk, so resolve dynamically.
TriggerGameRestart(reason, RL := true) {
    prof := Prof_Scope(A_ThisFunc)
    restartFn := Func("restartGameInstance")
    if (restartFn) {
        if (RL = false || RL = 0)
            restartFn.Call(reason, false)
        else if (RL != true && RL != "")
            restartFn.Call(reason, RL)
        else
            restartFn.Call(reason)
        return true
    }

    LogWarn("[" . A_ScriptName . "] TriggerGameRestart fallback: " . reason, "ADB.txt")
    closePTCGPApp()
    Sleep, 3000
    startPTCGPApp()
    return false
}

; Returns true when a restart was triggered and the caller should stop searching.
; bootPhase=true enables focus recovery; use only during waitForAppBootScreen().
handleAppHealthDuringSearch(imageName, bootPhase := false) {
    prof := Prof_Scope(A_ThisFunc)
    static refocusFailures := 0

    if (isTerminatePTCGPAppByADBShell()) {
        refocusFailures := 0
        TriggerGameRestart("Stuck at " . imageName . "... (App terminated)")
        return true
    }

    if (!bootPhase)
        return false

    if (!isPTCGPAppInFocus()) {
        LogInfo("App running but not in focus during boot; bringing to foreground", "ADB.txt")
        bringPTCGPAppToForeground()
        Sleep, 1500
        if (!isPTCGPAppInFocus()) {
            refocusFailures++
            if (refocusFailures >= 3) {
                refocusFailures := 0
                TriggerGameRestart("Stuck at " . imageName . "... (App lost focus)")
                return true
            }
        } else {
            refocusFailures := 0
        }
    } else {
        refocusFailures := 0
    }

    return false
}

isTerminatePTCGPAppByADBShell() {
    prof := Prof_Scope(A_ThisFunc)
    static cachedResult := ""
    static cachedAt := 0
    static marker := "__PTCGPB_CRASHLOG__"
    cacheTtlMs := 5000

    if (cachedResult != "" && (A_TickCount - cachedAt) < cacheTtlMs) {
        ADB_LogTrace("isTerminatePTCGPAppByADBShell cachedResult=" . cachedResult)
        return cachedResult
    }

    ; One round trip through the persistent shell: pid check and crash log together.
    result := adbWriteRaw("pidof jp.pokemon.pokemontcgp; echo " . marker . "; " . PTCGPAppCrashLogcatCommand(), true, 10000)
    markerPos := InStr(result, marker)
    pidPart := markerPos ? SubStr(result, 1, markerPos - 1) : result
    crashLog := markerPos ? SubStr(result, markerPos + StrLen(marker)) : ""
    ADB_LogTrace("isTerminatePTCGPAppByADBShell pidResult=" . Trim(pidPart, " `t`r`n"))

    if (!RegExMatch(pidPart, "(\d+)", currentPid)) {
        cachedResult := true
    } else {
        pid := resolvePTCGPAppPid(currentPid1)
        crashLine := findPTCGPAppCrashLine(crashLog, pid)
        if (crashLine != "") {
            LogWarn("[" . A_ScriptName . "] PTCGPApp crash detected in logcat: " . crashLine, "ADB.txt")
            cachedResult := true
        } else {
            cachedResult := false
        }
    }

    cachedAt := A_TickCount
    return cachedResult
}

isTerminatePTCGPHelperApp(){
    prof := Prof_Scope(A_ThisFunc)
    global session

    adbCommand := session.get("adbPath") . " -s " . AdbAddress()
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

    adbCommand := session.get("adbPath") . " -s " . AdbAddress()
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

; Reads shell output until the next "done" marker.
; status is set to "done", "dead" (shell died and was reinitialized) or "timeout" (shell was replaced).
; StdOut.AtEndOfStream blocks until output arrives, so no polling sleep is needed between lines.
adbReadUntilDone(isReturnning, timeoutMs, ByRef status, command := "") {
    global session
    result := ""
    status := ""
    startTime := A_TickCount

    Loop {
        shell := session.get("adbShell")

        ; Status turns non-zero once adb.exe exits. "Process, Exist" costs ~14ms per call,
        ; so it is only used below, when the output stream has ended.
        if (adbShellIsDead(shell, false)) {
            ADB_LogTrace("adbWriteRaw detected dead shell while waiting for command")
            initializeAdbShell()
            status := "dead"
            return result
        }

        if (timeoutMs > 0 && (A_TickCount - startTime) > timeoutMs) {
            ADB_LogTrace("adbWriteRaw timeout elapsedMs=" . (A_TickCount - startTime) . " command=" . ADB_RedactCommand(command))
            try {
                shell.Terminate()
            } catch e2 {
            }
            session.set("adbShell", "")
            initializeAdbShell()
            status := "timeout"
            return result
        }

        if (shell.StdOut.AtEndOfStream) {
            if (adbShellIsDead(shell, true)) {
                ADB_LogTrace("adbWriteRaw detected dead shell while waiting for command")
                initializeAdbShell()
                status := "dead"
                return result
            }
            Sleep, 50
            continue
        }

        line := RTrim(shell.StdOut.ReadLine(), "`r")
        if (line = "done") {
            status := "done"
            return result
        }

        if (isReturnning)
            result .= line . "`n"
    }
}

; checkProcess=false only reads the exec object's Status (cheap). checkProcess=true also
; asks Windows whether adb.exe still exists, which costs ~14ms.
adbShellIsDead(shell, checkProcess := false) {
    if (!IsObject(shell) || shell.Status != 0)
        return true

    if (checkProcess) {
        pid := shell.ProcessID
        Process, Exist, %pid%
        if (!ErrorLevel)
            return true
    }
    return false
}

adbPendingAckCount() {
    global session
    pending := session.get("adbPendingAcks")
    return (pending = "") ? 0 : pending
}

; Consumes the "done" markers of commands sent with adbWriteNoWait, so the next reader
; only sees output of its own command. Blocks until the device finished those commands.
adbDrainPendingCommands() {
    global session
    pending := adbPendingAckCount()
    if (pending <= 0)
        return true

    prof := Prof_Scope(A_ThisFunc)
    session.set("adbPendingAcks", 0)
    Loop, %pending% {
        status := ""
        adbReadUntilDone(false, 10000, status, "<pending ack>")
        ; A dead or replaced shell takes the remaining markers with it.
        if (status != "done")
            return false
    }
    return true
}

; Sends a command without waiting for the device to finish it. Use for input events whose
; output is not needed. At most one such command is in flight: the next ADB command first
; waits for it, so ordering on the device is unchanged and taps cannot pile up.
adbWriteNoWait(command) {
    prof := Prof_Scope(A_ThisFunc)
    global session

    Loop, 3 {
        try {
            adbDrainPendingCommands()
            ; A broken pipe makes WriteLine throw, which the catch below handles.
            if (adbShellIsDead(session.get("adbShell"), false)) {
                session.set("adbShell", "")
                initializeAdbShell()
            }
            ADB_LogTrace("adbWriteNoWait send command=" . ADB_RedactCommand(command))
            session.get("adbShell").StdIn.WriteLine(command . ";echo done;")
            session.set("adbPendingAcks", adbPendingAckCount() + 1)
            return true
        } catch e {
            errorMessage := IsObject(e) ? e.Message : e
            LogWarn("[" . A_ScriptName . "] ADB no-wait write error(" . A_Index . "/3) Command: " . ADB_RedactCommand(command) . ", Error: " . errorMessage, "ADB.txt")
            session.set("adbShell", "")
            initializeAdbShell()
        }
    }

    ; Fall back to a blocking write, which has its own retry and reconnect handling.
    return adbWriteRaw(command)
}

adbWriteRaw(command, isReturnning := false, timeoutMs := 60000) {
    prof := Prof_Scope(A_ThisFunc)
    global session
    retries := 0
    MaxRetries := 3
    loopCount := 0

    Loop {
        try {
            adbDrainPendingCommands()
            ADB_LogTrace("adbWriteRaw send returning=" . (isReturnning ? 1 : 0) . " timeoutMs=" . timeoutMs . " command=" . ADB_RedactCommand(command))
            session.get("adbShell").StdIn.WriteLine(command . ";echo done;")

            status := ""
            result := adbReadUntilDone(isReturnning, timeoutMs, status, command)
            if (status = "done") {
                if (isReturnning) {
                    ADB_LogTrace("adbWriteRaw done outputBytes=" . StrLen(result))
                    return result
                }
                ADB_LogTrace("adbWriteRaw done")
                return true
            }

            if (status = "timeout")
                return isReturnning ? result : false

            ; status = "dead": the shell was reinitialized, send the command again.
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
    global botConfig
    static clickCommands := Object()
    static lastClickTime := 0
    static convX := 540/283, convY := 960/488, offset :=40

    minDelay := botConfig.get("clickDelayMin") + 0
    maxDelay := botConfig.get("clickDelayMax") + 0
    if (minDelay < 0)
        minDelay := 0
    if (maxDelay < minDelay)
        maxDelay := minDelay

    Random, clickDelay, %minDelay%, %maxDelay%
    elapsed := A_TickCount - lastClickTime
    if (lastClickTime && elapsed < clickDelay) {
        remaining := clickDelay - elapsed
        Sleep, %remaining%
    }

    key := X << 16 | Y

    if (!clickCommands.HasKey(key)) {
        clickCommands[key] := Format("input tap {} {}"
            , Round(X * convX)
            , Round((Y - offset) * convY))
    }
    ADB_LogTrace("adbClick logical=(" . X . "," . Y . ") command=" . clickCommands[key])
    adbWriteNoWait(clickCommands[key])
    lastClickTime := A_TickCount
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
        adbWriteNoWait("input keycombination " . event)
    } else {
        ; It's a single key event (e.g., "67")
        adbWriteNoWait("input keyevent " . event)
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

    deviceAddress := AdbAddress()
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
        deviceAddress := AdbAddress()
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
        deviceAddress := AdbAddress()
        command := baseCommand . " exec-out screencap -p > """ .  outputFile . """"
        ADB_LogTrace("adbTakeScreenshot using exec-out fallback because save failed")
        RunWait, %ComSpec% /c "%command%", , Hide
        return
    }
}
