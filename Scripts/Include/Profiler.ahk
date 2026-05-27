;===============================================================================
; Profiler.ahk - Lightweight function timing for AutoHotkey v1
;===============================================================================
; Enable with Settings.ini [ToolsAndSystem] profileMode=1.
; Results are written to Logs\profile_<script>_<timestamp>.csv on exit/reload.
;===============================================================================

global PROF_DATA := {}
global PROF_ENABLED := Prof_IsEnabled()
global PROF_ONEXIT_REGISTERED := false

Prof_Init() {
    global PROF_ENABLED, PROF_ONEXIT_REGISTERED

    PROF_ENABLED := Prof_IsEnabled()
    if (PROF_ENABLED && !PROF_ONEXIT_REGISTERED) {
        OnExit("Prof_OnExit")
        PROF_ONEXIT_REGISTERED := true
    }
}

Prof_IsEnabled() {
    settingsPath := Prof_SettingsPath()
    IniRead, enabled, %settingsPath%, ToolsAndSystem, profileMode, 0
    if (enabled = "ERROR" || enabled = "")
        enabled := 0
    return enabled + 0
}

Prof_SettingsPath() {
    if (FileExist(A_ScriptDir . "\..\Settings.ini"))
        return A_ScriptDir . "\..\Settings.ini"
    if (FileExist(A_ScriptDir . "\..\..\Settings.ini"))
        return A_ScriptDir . "\..\..\Settings.ini"
    return A_ScriptDir . "\Settings.ini"
}

Prof_LogsDir() {
    if (FileExist(A_ScriptDir . "\..\Logs"))
        return A_ScriptDir . "\..\Logs"
    if (FileExist(A_ScriptDir . "\..\..\Logs"))
        return A_ScriptDir . "\..\..\Logs"
    return A_ScriptDir . "\Logs"
}

Prof_Scope(name) {
    global PROF_ENABLED

    if (!PROF_ENABLED)
        return ""
    return new ProfScope(name)
}

Prof_Record(name, elapsedMs) {
    global PROF_DATA, PROF_ENABLED

    if (!PROF_ENABLED || name = "")
        return

    if (!PROF_DATA.HasKey(name))
        PROF_DATA[name] := {calls: 0, total: 0, max: 0, min: ""}

    row := PROF_DATA[name]
    row.calls += 1
    row.total += elapsedMs
    if (elapsedMs > row.max)
        row.max := elapsedMs
    if (row.min = "" || elapsedMs < row.min)
        row.min := elapsedMs
}

Prof_Report(path := "") {
    global PROF_DATA, PROF_ENABLED

    if (!PROF_ENABLED || !IsObject(PROF_DATA) || PROF_DATA.Count() = 0)
        return ""

    if (path = "") {
        logsDir := Prof_LogsDir()
        if (!FileExist(logsDir))
            FileCreateDir, %logsDir%

        scriptName := StrReplace(A_ScriptName, ".ahk")
        path := logsDir . "\profile_" . scriptName . "_" . A_Now . ".csv"
    }

    FileDelete, %path%
    FileAppend, % "Function,Calls,TotalMs,AvgMs,MinMs,MaxMs`n", %path%

    for name, row in PROF_DATA {
        avg := row.calls ? Round(row.total / row.calls, 2) : 0
        FileAppend, % Prof_Csv(name) "," row.calls "," row.total "," avg "," row.min "," row.max "`n", %path%
    }

    return path
}

Prof_OnExit(exitReason, exitCode) {
    Prof_Report()
}

Prof_Csv(value) {
    value := StrReplace(value, """", """""")
    if (InStr(value, ",") || InStr(value, """") || InStr(value, "`n") || InStr(value, "`r"))
        return """" . value . """"
    return value
}

class ProfScope {
    __New(name) {
        this.name := name
        this.start := A_TickCount
    }

    __Delete() {
        Prof_Record(this.name, A_TickCount - this.start)
    }
}

Prof_Init()
