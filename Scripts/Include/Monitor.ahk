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

OnExit("CloseJobOnExit")

global botConfig := new BotConfig()
botConfig.loadSettingsToConfig("ALL")

lastReduceMemory := 0
lastBackup := 0

waitAfterBulkLaunch := botConfig.get("waitAfterBulkLaunch")
instanceLaunchDelay := botConfig.get("instanceLaunchDelay")
Instances := botConfig.get("Instances") + 0
Mains := botConfig.get("runMain") ? (botConfig.get("Mains") + 0) : 0
saveToGit := botConfig.get("saveToGit")
saveToDisk := botConfig.get("saveToDisk")
diskBackupFolder := botConfig.get("diskBackupFolder")
backupIntervalMinutes := botConfig.get("backupIntervalMinutes") + 0
if (backupIntervalMinutes < 5)
    backupIntervalMinutes := 5
deleteMethod := botConfig.get("deleteMethod")
memoryCapEnabled := botConfig.get("memoryCapEnabled")
memoryCapPerProcessMB := botConfig.get("memoryCapPerProcessMB") + 0
memoryCapTotalMB := botConfig.get("memoryCapTotalMB") + 0
memoryCapMarginMB := botConfig.get("memoryCapMarginMB") + 0
cpuAffinityEnabled := botConfig.get("cpuAffinityEnabled")
cpuAffinityCoresPerInstance := botConfig.get("cpuAffinityCoresPerInstance") + 0

; Negative or malformed values fall back to auto
if (memoryCapPerProcessMB < 0)
    memoryCapPerProcessMB := 0
if (memoryCapTotalMB < 0)
    memoryCapTotalMB := 0
if (memoryCapMarginMB < 0)
    memoryCapMarginMB := 0
if (cpuAffinityCoresPerInstance < 0)
    cpuAffinityCoresPerInstance := 0

mumuFolder := getMuMuFolder()

if !FileExist(mumuFolder){
    MsgBox, 16, , Double check your folder path! It should be the one that contains the MuMuPlayer 12 folder! `nDefault is just C:\Program Files\Netease
    ExitApp
}

; Auto-dimensionamento: valori 0 = calcolo automatico
; Margine auto = max(2048, RAM fisica * 12%)
; Totale auto = RAM fisica - margine
; Per-processo auto = Totale / numero istanze (min 2048 MB)
if (memoryCapEnabled) {
    if (memoryCapTotalMB = 0) {
        physMB := GetPhysicalMemoryMB()
        if (memoryCapMarginMB = 0) {
            memoryCapMarginMB := physMB * 12 // 100
            if (memoryCapMarginMB < 2048)
                memoryCapMarginMB := 2048
        }
        memoryCapTotalMB := physMB - memoryCapMarginMB
        if (memoryCapTotalMB < 4096)
            memoryCapTotalMB := 4096
        LogInfo("Memory cap auto: physical RAM " . physMB . " MB, margin " . memoryCapMarginMB . " MB, total cap set to " . memoryCapTotalMB . " MB", "Monitor.txt")
    }
    if (memoryCapPerProcessMB = 0) {
        instanceCount := Instances + Mains
        if (instanceCount < 1)
            instanceCount := 1
        memoryCapPerProcessMB := memoryCapTotalMB // instanceCount
        if (memoryCapPerProcessMB < 2048)
            memoryCapPerProcessMB := 2048
        LogInfo("Memory cap auto: " . instanceCount . " instances, per-process cap set to " . memoryCapPerProcessMB . " MB", "Monitor.txt")
    }
}

global g_hJob := 0
global g_assignedPIDs := {}

if (memoryCapEnabled) {
    g_hJob := InitMemoryCapJob(memoryCapPerProcessMB, memoryCapTotalMB)
    if (g_hJob)
        LogInfo("Memory cap job created. Per-process: " . memoryCapPerProcessMB . " MB, Total: " . memoryCapTotalMB . " MB", "Monitor.txt")
    else
        LogInfo("Memory cap job creation FAILED.", "Monitor.txt")
}

; CPU affinity auto-dimensionamento
; Reserve = max(1, totalLogical // 8) per Windows e altre app
; Cores per instance = max(1, available // instanceCount)
; Assegnazione round-robin con wrap-around (nessuna istanza senza core)
if (cpuAffinityEnabled) {
    if (cpuAffinityCoresPerInstance = 0) {
        totalLogical := GetLogicalProcessorCount()
        if (totalLogical > 64)
            totalLogical := 64
        affinityReserve := totalLogical // 8
        if (affinityReserve < 1)
            affinityReserve := 1
        affinityAvailable := totalLogical - affinityReserve
        instanceCount := Instances + Mains
        if (instanceCount < 1)
            instanceCount := 1
        cpuAffinityCoresPerInstance := affinityAvailable // instanceCount
        if (cpuAffinityCoresPerInstance < 1)
            cpuAffinityCoresPerInstance := 1
        LogInfo("CPU affinity auto: " . totalLogical . " logical processors, " . affinityReserve . " reserved, " . affinityAvailable . " available, " . instanceCount . " instances, " . cpuAffinityCoresPerInstance . " cores per instance", "Monitor.txt")
    }
    global g_affinityAssignedPIDs := {}
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

    if (A_TickCount - lastReduceMemory > 120000) {
        ReduceVMMemory()
        lastReduceMemory := A_TickCount
    }

    if (g_hJob)
        AssignMuMuInstancesToJob(g_hJob)

    if (cpuAffinityEnabled)
        SetMuMuAffinity(cpuAffinityCoresPerInstance)

    ; Check for dead instances every 30 seconds
    Sleep, 30000
}

ReduceVMMemory(){
    targetProcesses := ["MuMuVMMHeadless.exe", "MuMuNxDevice.exe"]
    CleanedCount := 0
    TotalReducedKB := 0

    for idx, TargetProcess in targetProcesses {
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
                    TotalReducedKB += (MemBefore - MemAfter)
                    CleanedCount++
                }
            }
        }
    }
    LogInfo("ReduceVMMemory: flushed " . Round(TotalReducedKB / 1024, 1) . " MB from " . CleanedCount . " process(es)", "Monitor.txt")
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

GetPhysicalMemoryMB() {
    VarSetCapacity(memStatus, 64, 0)
    NumPut(64, memStatus, 0, "UInt")
    if (DllCall("GlobalMemoryStatusEx", "Ptr", &memStatus)) {
        return NumGet(memStatus, 8, "UInt64") // (1024 * 1024)
    }
    return 0
}

InitMemoryCapJob(perProcessMB, totalMB) {
    hJob := DllCall("CreateJobObjectW", "Ptr", 0, "Ptr", 0, "Ptr")
    if (!hJob)
        return 0

    ; JOBOBJECT_EXTENDED_LIMIT_INFORMATION (144 bytes on 64-bit)
    VarSetCapacity(joeli, 144, 0)

    ; LimitFlags at offset 16: JOB_OBJECT_LIMIT_PROCESS_MEMORY (0x100) | JOB_OBJECT_LIMIT_JOB_MEMORY (0x200)
    NumPut(0x300, joeli, 16, "UInt")

    ; ProcessMemoryLimit at offset 112
    NumPut(perProcessMB * 1024 * 1024, joeli, 112, "Int64")

    ; JobMemoryLimit at offset 120
    NumPut(totalMB * 1024 * 1024, joeli, 120, "Int64")

    result := DllCall("SetInformationJobObject", "Ptr", hJob, "Int", 9, "Ptr", &joeli, "UInt", 144, "Int")
    if (!result) {
        DllCall("CloseHandle", "Ptr", hJob)
        return 0
    }

    return hJob
}

AssignMuMuInstancesToJob(hJob) {
    global g_assignedPIDs
    processNames := ["MuMuNxDevice.exe", "MuMuVMMHeadless.exe"]
    currentPIDs := {}
    assigned := 0

    for idx, procName in processNames {
        query := "Select ProcessId from Win32_Process Where Name = '" . procName . "'"
        for process in ComObjGet("winmgmts:").ExecQuery(query) {
            pid := process.ProcessId
            currentPIDs[pid] := true

            if (g_assignedPIDs.HasKey(pid))
                continue

            ; PROCESS_SET_QUOTA (0x0100) | PROCESS_TERMINATE (0x0001)
            hProcess := DllCall("OpenProcess", "UInt", 0x0101, "Int", false, "UInt", pid, "Ptr")
            if (hProcess) {
                result := DllCall("AssignProcessToJobObject", "Ptr", hJob, "Ptr", hProcess, "Int")
                DllCall("CloseHandle", "Ptr", hProcess)
                if (result) {
                    g_assignedPIDs[pid] := true
                    assigned++
                }
            }
        }
    }

    ; Remove dead PIDs from tracking
    deadPIDs := []
    for pid in g_assignedPIDs {
        if (!currentPIDs.HasKey(pid))
            deadPIDs.Push(pid)
    }
    for idx, pid in deadPIDs {
        g_assignedPIDs.Delete(pid)
    }

    if (assigned > 0)
        LogInfo("Memory cap: assigned " . assigned . " process(es) to job.", "Monitor.txt")
}

CloseJobOnExit(ExitReason, ExitCode) {
    global g_hJob
    if (g_hJob) {
        DllCall("CloseHandle", "Ptr", g_hJob)
        g_hJob := 0
    }
    return 0
}

GetLogicalProcessorCount() {
    EnvGet, numProcs, NUMBER_OF_PROCESSORS
    return numProcs + 0
}

SetMuMuAffinity(coresPerInstance) {
    global g_affinityAssignedPIDs

    if (coresPerInstance < 1)
        return

    totalLogical := GetLogicalProcessorCount()
    if (totalLogical < 1)
        return
    ; SetProcessAffinityMask works within a single processor group (max 64)
    if (totalLogical > 64)
        totalLogical := 64

    reserve := totalLogical // 8
    if (reserve < 1)
        reserve := 1
    available := totalLogical - reserve
    if (available < 1)
        available := 1

    pidList := ""
    for process in ComObjGet("winmgmts:").ExecQuery("Select ProcessId from Win32_Process Where Name = 'MuMuNxDevice.exe'") {
        pidList .= process.ProcessId . "`n"
    }
    Sort, pidList, N

    ; Prune dead PIDs first so their slots become reusable
    currentPIDs := {}
    Loop, Parse, pidList, `n
    {
        if (A_LoopField = "")
            continue
        currentPIDs[A_LoopField + 0] := true
    }
    deadPIDs := []
    for pid in g_affinityAssignedPIDs {
        if (!currentPIDs.HasKey(pid))
            deadPIDs.Push(pid)
    }
    for idx, pid in deadPIDs {
        g_affinityAssignedPIDs.Delete(pid)
    }

    ; Slot-based assignment: each PID keeps its slot for its lifetime;
    ; new PIDs take the lowest free slot, so restarts reuse freed cores
    ; instead of overlapping with running instances.
    usedSlots := {}
    for pid, slot in g_affinityAssignedPIDs
        usedSlots[slot] := true

    assigned := 0
    Loop, Parse, pidList, `n
    {
        if (A_LoopField = "")
            continue
        pid := A_LoopField + 0

        if (g_affinityAssignedPIDs.HasKey(pid))
            continue

        slot := 0
        while (usedSlots.HasKey(slot))
            slot++

        startCore := Mod(slot * coresPerInstance, available)
        mask := 0
        Loop %coresPerInstance% {
            core := reserve + Mod(startCore + A_Index - 1, available)
            mask := mask | (1 << core)
        }

        hProcess := DllCall("OpenProcess", "UInt", 0x0200, "Int", false, "UInt", pid, "Ptr")
        if (hProcess) {
            result := DllCall("SetProcessAffinityMask", "Ptr", hProcess, "Int64", mask, "Int")
            DllCall("CloseHandle", "Ptr", hProcess)
            if (result) {
                g_affinityAssignedPIDs[pid] := slot
                usedSlots[slot] := true
                assigned++
            }
        }
    }

    if (assigned > 0)
        LogInfo("CPU affinity: set " . coresPerInstance . " cores for " . assigned . " process(es)", "Monitor.txt")
}

~+F7::ExitApp
