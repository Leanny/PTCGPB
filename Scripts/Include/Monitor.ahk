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

            killedAHK := killAHK(scriptName)
            killedInstance := killInstance(instanceNum)
            Sleep, 3000

            cntAHK := checkAHK(scriptName)
            pID := checkInstance(instanceNum)
            if not pID && not cntAHK {
                ; Change the last end date to now so that we don't keep trying to restart this beast
                IniWrite, %nowEpoch%, %iniPath%, Metrics, LastEndEpoch
                IniWrite, 0, %iniPath%, Metrics, LastActivityEpoch

                launchInstance(instanceNum)

                sleepTime := instanceLaunchDelay * 1000
                Sleep, % sleepTime
                launched := launched + 1

                Sleep, %waitAfterBulkLaunch%

                ;Command := "Scripts\" . scriptName
                ;Run, %Command%
                scriptPath := A_ScriptDir "\.." "\" scriptName
                Run, "%A_AhkPath%" /restart "%scriptPath%"
                LogInfo("Monitor restarted instance " . instanceNum . ". Reason: " . progressSource . " recorded "
                    . secondsSinceLastProgress . " seconds ago", "Log_" . instanceNum . ".txt")
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
