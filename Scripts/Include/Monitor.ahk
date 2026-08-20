#Include %A_ScriptDir%\Config.ahk
#Include %A_ScriptDir%\Profiler.ahk
#Include %A_ScriptDir%\Logging.ahk
#Include %A_ScriptDir%\GitManager.ahk
#Include %A_ScriptDir%\MumuHelper.ahk
#Include %A_ScriptDir%\Utils.ahk

#SingleInstance, force
CoordMode, Mouse, Screen
SetTitleMatchMode, 3

if not A_IsAdmin
{
    ; Relaunch script with admin rights
    Run *RunAs "%A_ScriptFullPath%"
    ExitApp
}

global botConfig := new BotConfig()
botConfig.loadSettingsToConfig("ALL")

lastReduceMemory := 0
lastBackup := 0

waitAfterBulkLaunch := botConfig.get("waitAfterBulkLaunch")
instanceLaunchDelay := botConfig.get("instanceLaunchDelay")
Instances := botConfig.get("Instances")
saveToGit := botConfig.get("saveToGit")
saveToDisk := botConfig.get("saveToDisk")
diskBackupFolder := botConfig.get("diskBackupFolder")
backupIntervalMinutes := botConfig.get("backupIntervalMinutes") + 0
if (backupIntervalMinutes < 5)
    backupIntervalMinutes := 5
deleteMethod := botConfig.get("deleteMethod")

mumuFolder := getMuMuFolder()

if !FileExist(mumuFolder){
    MsgBox, 16, , Double check your folder path! It should be the one that contains the MuMuPlayer 12 folder! `nDefault is just C:\Program Files\Netease
    ExitApp
}

; Reset LastEndEpoch for all instances at startup so stale timestamps from
; a previous session don't immediately trigger the stuck detection.
nowEpoch := A_NowUTC
EnvSub, nowEpoch, 1970, seconds
Loop %Instances% {
    instanceNum := Format("{:u}", A_Index)
    iniPath := GetScriptIniPathByName(instanceNum)
    IniWrite, %nowEpoch%, %iniPath%, Metrics, LastEndEpoch
    IniWrite, 0, %iniPath%, Metrics, LastActivityEpoch
}

Loop {
    ; Loop through each instance, check if it's started, and start it if it's not
    launched := 0

    Loop %Instances% {
        ; Recalculate epoch each iteration so it stays fresh after restart sleeps
        nowEpoch := A_NowUTC
        EnvSub, nowEpoch, 1970, seconds

        ; if(A_TickCount - lastReduceMemory > 120000) {
        ;     LogInfo("Memory reduction process start.", "Monitor.txt")
        ;     ReduceVMMemory()
        ;     LogInfo("Memory reduction process complete.", "Monitor.txt")
        ;     lastReduceMemory := A_TickCount
        ; }

        instanceNum := Format("{:u}", A_Index)

        iniPath := GetScriptIniPathByName(instanceNum)
        IniRead, LastEndEpoch, %iniPath%, Metrics, LastEndEpoch, 0
        IniRead, LastStartEpoch, %iniPath%, Metrics, LastStartEpoch, 0
        IniRead, LastActivityEpoch, %iniPath%, Metrics, LastActivityEpoch, 0
        ; Set threshold: 30 minutes for Create Bots, 11 minutes for others
        threshold := (deleteMethod == "Create Bots (13P)") ? (30 * 60) : (11 * 60)
        ; Use LastEndEpoch if available, otherwise fall back to LastStartEpoch for first-run detection
        if (LastEndEpoch > 0) {
            secondsSinceLastProgress := nowEpoch - LastEndEpoch
            progressSource := "LastEndEpoch"
            isStuck := (secondsSinceLastProgress > threshold)
        } else if (LastStartEpoch > 0) {
            secondsSinceLastProgress := nowEpoch - LastStartEpoch
            progressSource := "LastStartEpoch"
            isStuck := (secondsSinceLastProgress > threshold)
        } else {
            secondsSinceLastProgress := 0
            progressSource := ""
            isStuck := false
        }
        ; Long-running work (for example pack opening, reset waits, and friend
        ; add/remove flows) can outlive LastEndEpoch.
        if (LastActivityEpoch > 0 && LastActivityEpoch > LastEndEpoch) {
            secondsSinceLastProgress := nowEpoch - LastActivityEpoch
            progressSource := "LastActivityEpoch"
            isStuck := (secondsSinceLastProgress > threshold)
        }
        if(isStuck)
        {
            if (progressSource = "LastActivityEpoch")
                msg := "Killing Instance " . instanceNum . "! Activity last updated " . secondsSinceLastProgress . " seconds ago"
            else
                msg := "Killing Instance " . instanceNum . "! Last Run Completed " . secondsSinceLastProgress . " Seconds Ago"
            LogInfo(msg, "Monitor.txt")

            scriptName := instanceNum . ".ahk"
            coverHwnd := CaptureMuMuCoverWindow(instanceNum)
            StoreMuMuCoverWindow(instanceNum, coverHwnd)

            recovered := RecoverMonitoredInstance(instanceNum, scriptName)
            if (recovered) {
                ; Only reset the watchdog after the replacement MuMu window and
                ; AHK process have both been observed. Issuing launch commands is
                ; not sufficient evidence that recovery worked.
                recoveryEpoch := A_NowUTC
                EnvSub, recoveryEpoch, 1970, seconds
                IniWrite, %recoveryEpoch%, %iniPath%, Metrics, LastEndEpoch
                IniWrite, 0, %iniPath%, Metrics, LastActivityEpoch
                launched := launched + 1
                LogInfo("Monitor restarted instance " . instanceNum . ". Reason: " . progressSource . " recorded "
                    . secondsSinceLastProgress . " seconds ago", "Log_" . instanceNum . ".txt")
            } else {
                LogError("Recovery " . instanceNum . ": FAILED; watchdog timestamp was not reset and recovery will be retried", "Monitor.txt")
            }
        }
    }

    intervalMs := backupIntervalMinutes * 60000
    if ((saveToGit || saveToDisk) && A_TickCount - lastBackup > intervalMs) {
        gitRoot := A_ScriptDir . "\..\.."
        paths := BuildBackupPaths(botConfig)
        if (!paths.MaxIndex()) {
            LogInfo("Backup skipped: no categories selected.", "Monitor.txt")
            lastBackup := A_TickCount
        } else {
            ok := true
            if (saveToGit) {
                LogInfo("Git auto-commit start.", "Monitor.txt")
                if (!CommitAndPushGit(gitRoot, "Monitor.txt", paths))
                    ok := false
            }
            if (saveToDisk) {
                LogInfo("Disk auto-backup start.", "Monitor.txt")
                if (!BackupToDisk(gitRoot, diskBackupFolder, paths, "Monitor.txt"))
                    ok := false
            }
            if (ok)
                lastBackup := A_TickCount
        }
    }

    ; Check for dead instances every 30 seconds
    Sleep, 30000
}

RecoverMonitoredInstance(instanceNum, scriptName) {
    global instanceLaunchDelay, waitAfterBulkLaunch, mumuFolder

    vmFolderName := MonitorGetMuMuVmFolderName(instanceNum)
    windowPid := checkInstance(instanceNum)
    backendPids := MonitorGetMuMuBackendPids(vmFolderName)
    LogInfo("Recovery " . instanceNum . ": start; window PID=" . MonitorValueOrNone(windowPid)
        . ", backend PIDs=" . MonitorJoinPids(backendPids)
        . ", VM folder=" . MonitorValueOrNone(vmFolderName), "Monitor.txt")

    killedAHK := killAHK(scriptName)
    LogInfo("Recovery " . instanceNum . ": requested termination of " . killedAHK . " AHK process(es)", "Monitor.txt")
    if (!MonitorWaitForAHKExit(scriptName, 10000)) {
        LogError("Recovery " . instanceNum . ": AHK process still present after 10 seconds", "Monitor.txt")
        return false
    }

    managerPid := MonitorRequestMuMuShutdown(instanceNum)
    if (managerPid)
        LogInfo("Recovery " . instanceNum . ": MuMu Manager shutdown requested; command PID=" . managerPid, "Monitor.txt")
    else
        LogWarn("Recovery " . instanceNum . ": MuMu Manager shutdown could not be started; using bounded fallback", "Monitor.txt")

    stoppedGracefully := MonitorWaitForMuMuExit(instanceNum, vmFolderName, 15000)
    MonitorFinishManagerCommand(managerPid, instanceNum)
    if (!stoppedGracefully) {
        LogWarn("Recovery " . instanceNum . ": graceful shutdown timed out; terminating the scoped window/backend processes", "Monitor.txt")
        killedWindow := killInstance(instanceNum)
        killedBackends := MonitorKillMuMuBackendPids(vmFolderName)
        LogInfo("Recovery " . instanceNum . ": fallback requested window kills=" . killedWindow
            . ", backend kills=" . killedBackends, "Monitor.txt")

        if (!MonitorWaitForMuMuExit(instanceNum, vmFolderName, 10000)) {
            remainingWindowPid := checkInstance(instanceNum)
            remainingBackends := MonitorGetMuMuBackendPids(vmFolderName)
            LogError("Recovery " . instanceNum . ": MuMu did not stop; window PID="
                . MonitorValueOrNone(remainingWindowPid) . ", backend PIDs=" . MonitorJoinPids(remainingBackends), "Monitor.txt")
            return false
        }
    }

    LogInfo("Recovery " . instanceNum . ": MuMu stopped; launching replacement instance", "Monitor.txt")
    launchStartTick := A_TickCount
    launchInstance(instanceNum)

    configuredLaunchDelayMs := (instanceLaunchDelay * 1000) + waitAfterBulkLaunch
    launchTimeoutMs := configuredLaunchDelayMs
    if (launchTimeoutMs < 30000)
        launchTimeoutMs := 30000
    if (!MonitorWaitForMuMuStart(instanceNum, launchTimeoutMs)) {
        LogError("Recovery " . instanceNum . ": replacement MuMu window did not become responsive within "
            . Round(launchTimeoutMs / 1000) . " seconds", "Monitor.txt")
        return false
    }

    remainingLaunchDelayMs := configuredLaunchDelayMs - (A_TickCount - launchStartTick)
    if (remainingLaunchDelayMs > 0) {
        LogInfo("Recovery " . instanceNum . ": MuMu window is responsive; waiting "
            . Round(remainingLaunchDelayMs / 1000) . " more seconds before starting AHK", "Monitor.txt")
        Sleep, %remainingLaunchDelayMs%
    }
    if (!MonitorWaitForMuMuStart(instanceNum, 2000)) {
        LogError("Recovery " . instanceNum . ": MuMu became unresponsive during its startup delay", "Monitor.txt")
        return false
    }

    scriptPath := A_ScriptDir "\.." "\" scriptName
    Run, "%A_AhkPath%" /restart "%scriptPath%",, UseErrorLevel, newAhkPid
    if (ErrorLevel) {
        LogError("Recovery " . instanceNum . ": failed to launch " . scriptName . "; ErrorLevel=" . ErrorLevel, "Monitor.txt")
        return false
    }

    if (!MonitorWaitForAHKStart(scriptName, 10000)) {
        LogError("Recovery " . instanceNum . ": replacement AHK was not observed; launch PID=" . newAhkPid, "Monitor.txt")
        return false
    }

    LogInfo("Recovery " . instanceNum . ": SUCCESS; MuMu window PID=" . checkInstance(instanceNum)
        . ", AHK launch PID=" . newAhkPid, "Monitor.txt")
    return true
}

MonitorRequestMuMuShutdown(instanceNum) {
    global mumuFolder

    mumuNum := getMumuInstanceNum(instanceNum, mumuFolder)
    if (mumuNum = "")
        return 0

    managerPath := mumuFolder . "\shell\MuMuManager.exe"
    if (!FileExist(managerPath))
        managerPath := mumuFolder . "\nx_main\MuMuManager.exe"
    if (!FileExist(managerPath))
        return 0

    command := """" . managerPath . """ control shutdown -v " . mumuNum
    Run, %command%,, Hide UseErrorLevel, managerPid
    if (ErrorLevel)
        return 0
    return managerPid
}

MonitorFinishManagerCommand(managerPid, instanceNum) {
    if (!managerPid)
        return

    Process, Exist, %managerPid%
    if (ErrorLevel != managerPid)
        return

    Process, Close, %managerPid%
    Process, WaitClose, %managerPid%, 2
    if (ErrorLevel)
        LogWarn("Recovery " . instanceNum . ": timed-out MuMu Manager command PID " . managerPid . " could not be terminated", "Monitor.txt")
    else
        LogInfo("Recovery " . instanceNum . ": terminated timed-out MuMu Manager command PID " . managerPid, "Monitor.txt")
}

MonitorGetMuMuVmFolderName(instanceNum) {
    global mumuFolder

    Loop, Files, %mumuFolder%\vms\*, D
    {
        extraConfigFile := A_LoopFileFullPath . "\configs\extra_config.json"
        if (!FileExist(extraConfigFile))
            continue
        FileRead, extraConfigContent, %extraConfigFile%
        if (ErrorLevel)
            continue
        RegExMatch(extraConfigContent, """playerName""\s*:\s*""(.*?)""", playerName)
        if (playerName1 = instanceNum)
            return A_LoopFileName
    }
    return ""
}

MonitorGetMuMuBackendPids(vmFolderName) {
    pids := []
    if (vmFolderName = "")
        return pids

    try {
        for process in ComObjGet("winmgmts:").ExecQuery("Select ProcessId, Name, CommandLine from Win32_Process Where Name like 'MuMu%'") {
            if (process.CommandLine != "" && InStr(process.CommandLine, vmFolderName))
                pids.Push(process.ProcessId + 0)
        }
    } catch e {
        LogError("Monitor backend lookup failed for " . vmFolderName . ": " . e.Message, "Monitor.txt")
    }
    return pids
}

MonitorKillMuMuBackendPids(vmFolderName) {
    killed := 0
    pids := MonitorGetMuMuBackendPids(vmFolderName)
    for _, pid in pids {
        Process, Close, %pid%
        Process, WaitClose, %pid%, 2
        if (!ErrorLevel)
            killed++
        else
            LogWarn("Monitor could not terminate scoped MuMu backend PID " . pid . " for " . vmFolderName, "Monitor.txt")
    }
    return killed
}

MonitorWaitForMuMuExit(instanceNum, vmFolderName, timeoutMs) {
    startTick := A_TickCount
    Loop {
        backendPids := MonitorGetMuMuBackendPids(vmFolderName)
        if (!checkInstance(instanceNum) && !backendPids.MaxIndex())
            return true
        if ((A_TickCount - startTick) >= timeoutMs)
            return false
        Sleep, 500
    }
}

MonitorWaitForMuMuStart(instanceNum, timeoutMs) {
    startTick := A_TickCount
    Loop {
        hwnd := WinExist(instanceNum . " ahk_class Qt5156QWindowIcon")
        if (hwnd && !DllCall("user32\IsHungAppWindow", "Ptr", hwnd))
            return true
        if ((A_TickCount - startTick) >= timeoutMs)
            return false
        Sleep, 500
    }
}

MonitorWaitForAHKExit(scriptName, timeoutMs) {
    startTick := A_TickCount
    Loop {
        if (!checkAHK(scriptName))
            return true
        if ((A_TickCount - startTick) >= timeoutMs)
            return false
        Sleep, 250
    }
}

MonitorWaitForAHKStart(scriptName, timeoutMs) {
    startTick := A_TickCount
    Loop {
        if (checkAHK(scriptName))
            return true
        if ((A_TickCount - startTick) >= timeoutMs)
            return false
        Sleep, 250
    }
}

MonitorJoinPids(pids) {
    if (!IsObject(pids) || !pids.MaxIndex())
        return "none"
    result := ""
    for _, pid in pids
        result .= (result = "" ? "" : ",") . pid
    return result
}

MonitorValueOrNone(value) {
    return (value = "") ? "none" : value
}
ReduceVMMemory(){
    TargetProcess := "MuMuVMMHeadless.exe"
    CleanedCount := 0

    for process in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process Where Name = '" TargetProcess "'")
    {
        PID := process.ProcessId

        hProcess := DllCall("OpenProcess", "UInt", 0x0400 | 0x0100 | 0x0010, "Int", false, "UInt", PID)

        if (hProcess)
        {
            MemBefore := GetProcessMemory(hProcess)
            Success := DllCall("psapi.dll\EmptyWorkingSet", "Ptr", hProcess)
            MemAfter := GetProcessMemory(hProcess)

            DllCall("CloseHandle", "Ptr", hProcess)

            if (Success) {
                ;ResultLine := "PID: " . PID . " | Before: " . Round(MemBefore, 1) . "KB | After: " . Round(MemAfter, 1) . "KB | Reduced size: " . Round(MemBefore-MemAfter, 1) . "KB`n"
                ;LogInfo(ResultLine, "Development.txt")
                CleanedCount++
            }
        }
    }
    LogInfo("Total reduce memory count: " . CleanedCount, "Monitor.txt")
    return CleanedCount
}

GetProcessMemory(hProcess) {
    VarSetCapacity(PMC, 72, 0)
    if (DllCall("psapi.dll\GetProcessMemoryInfo", "Ptr", hProcess, "Ptr", &PMC, "UInt", 72)) {
        addrOffset := (A_PtrSize = 8) ? 16 : 12
        bytes := NumGet(PMC, addrOffset, "UPtr")
        return bytes / 1024
    }
    return 0
}

killAHK(scriptName := "")
{
    killed := 0

    if(scriptName != "") {
        DetectHiddenWindows, On
        killedPIDs := {}
        killed += killAHKWindowsByClass(scriptName, "AutoHotkey", killedPIDs)
        killed += killAHKWindowsByClass(scriptName, "#32770", killedPIDs)
        killed += killAHKWindowsByClass(scriptName, "ConsoleWindowClass", killedPIDs)
        killed += killAHKProcessesByCommandLine(scriptName, killedPIDs)
    }

    return killed
}

checkAHK(scriptName := "")
{
    cnt := 0

    if(scriptName != "") {
        DetectHiddenWindows, On
        seenPIDs := {}
        cnt += countAHKWindowsByClass(scriptName, "AutoHotkey", seenPIDs)
        cnt += countAHKWindowsByClass(scriptName, "#32770", seenPIDs)
        cnt += countAHKWindowsByClass(scriptName, "ConsoleWindowClass", seenPIDs)
        cnt += countAHKProcessesByCommandLine(scriptName, seenPIDs)
    }

    return cnt
}

killAHKWindowsByClass(scriptName, winClass, killedPIDs)
{
    killed := 0
    WinGet, IDList, List, ahk_class %winClass%
    Loop %IDList%
    {
        ID:=IDList%A_Index%
        WinGetTitle, ATitle, ahk_id %ID%
        if (isAHKScriptWindowTitle(ATitle, scriptName)) {
            ; Use Process Close (TerminateProcess) instead of WinKill (WM_CLOSE)
            ; to guarantee the process dies even if blocked on ADB/Sleep.
            WinGet, ahkPID, PID, ahk_id %ID%
            if (ahkPID && !killedPIDs.HasKey(ahkPID)) {
                Process, Close, %ahkPID%
                killedPIDs[ahkPID] := true
                killed := killed + 1
            }
        }
    }

    return killed
}

countAHKWindowsByClass(scriptName, winClass, seenPIDs)
{
    cnt := 0
    WinGet, IDList, List, ahk_class %winClass%
    Loop %IDList%
    {
        ID:=IDList%A_Index%
        WinGetTitle, ATitle, ahk_id %ID%
        if (isAHKScriptWindowTitle(ATitle, scriptName)) {
            WinGet, ahkPID, PID, ahk_id %ID%
            if (ahkPID && !seenPIDs.HasKey(ahkPID)) {
                seenPIDs[ahkPID] := true
                cnt := cnt + 1
            }
        }
    }

    return cnt
}

killAHKProcessesByCommandLine(scriptName, killedPIDs)
{
    killed := 0
    scriptNeedle := "\" . scriptName

    for process in ComObjGet("winmgmts:").ExecQuery("Select ProcessId, Name, CommandLine from Win32_Process Where Name like 'AutoHotkey%'")
    {
        commandLine := process.CommandLine
        if(commandLine != "" && InStr(commandLine, scriptNeedle)) {
            ahkPID := process.ProcessId
            if (ahkPID && !killedPIDs.HasKey(ahkPID)) {
                Process, Close, %ahkPID%
                killedPIDs[ahkPID] := true
                killed := killed + 1
            }
        }
    }

    return killed
}

countAHKProcessesByCommandLine(scriptName, seenPIDs)
{
    cnt := 0
    scriptNeedle := "\" . scriptName

    for process in ComObjGet("winmgmts:").ExecQuery("Select ProcessId, Name, CommandLine from Win32_Process Where Name like 'AutoHotkey%'")
    {
        commandLine := process.CommandLine
        if(commandLine != "" && InStr(commandLine, scriptNeedle)) {
            ahkPID := process.ProcessId
            if (ahkPID && !seenPIDs.HasKey(ahkPID)) {
                seenPIDs[ahkPID] := true
                cnt := cnt + 1
            }
        }
    }

    return cnt
}

isAHKScriptWindowTitle(ATitle, scriptName)
{
    return (InStr(ATitle, "\" . scriptName) || ATitle = scriptName)
}

~+F7::ExitApp
