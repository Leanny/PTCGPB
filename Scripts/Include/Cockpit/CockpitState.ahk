;===============================================================================
; CockpitState.ahk - Lib for reading/writing the Cockpit state file
;===============================================================================
; The file `Scripts\Include\Cockpit\CockpitState.ini` is the single source of
; truth between
; the Aggregator (writer) and the Cockpit GUI (reader). It is rewritten
; atomically from a single producer (the Aggregator).
;
; Public API:
;   CockpitState_Path()                       -> absolute path
;   CockpitState_Exists()                     -> 1/0
;   CockpitState_AgeSeconds()                 -> seconds since last aggregator write
;   CockpitState_Read()                       -> assoc object with parsed state
;   CockpitState_GetField(section, key, def)  -> single value via IniRead
;   CockpitState_GetSection(section)          -> assoc { key: value }
;
;   CockpitState_NewBuilder()                 -> opaque builder object
;   CockpitState_AddSection(builder, name)
;   CockpitState_AddKey(builder, key, value)
;   CockpitState_Commit(builder)              -> writes atomically (.tmp -> .ini)
;   CockpitState_CommitTo(builder, path)      -> same, to an arbitrary INI path
;   CockpitState_ParseFile(path)              -> { section: {key: value} } in one FileRead
;   CockpitState_SecGet(sec, key, def)        -> parsed-section lookup with default
;
;   CockpitState_NowEpoch()                   -> seconds since 1970 (UTC)
;
;===============================================================================

CockpitState_Path() {
    return getScriptBaseFolder() . "\Scripts\Include\Cockpit\CockpitState.ini"
}

CockpitState_Exists() {
    return FileExist(CockpitState_Path()) ? 1 : 0
}

CockpitState_NowEpoch() {
    nowEpoch := A_NowUTC
    EnvSub, nowEpoch, 1970, seconds
    return nowEpoch
}

CockpitState_AgeSeconds() {
    path := CockpitState_Path()
    if (!FileExist(path))
        return -1

    FileGetTime, mtime, %path%, M
    nowLocal := A_Now
    EnvSub, nowLocal, %mtime%, Seconds
    return nowLocal
}

;-------------------------------------------------------------------------------
; Reading helpers
;-------------------------------------------------------------------------------
CockpitState_GetField(section, key, default := "") {
    path := CockpitState_Path()
    if (!FileExist(path))
        return default

    IniRead, value, %path%, %section%, %key%, %default%
    if (value = "ERROR")
        return default
    return value
}

CockpitState_GetSection(section) {
    obj := {}
    path := CockpitState_Path()
    if (!FileExist(path))
        return obj

    IniRead, raw, %path%, %section%
    if (raw = "" || raw = "ERROR")
        return obj

    Loop, Parse, raw, `n, `r
    {
        if (A_LoopField = "")
            continue
        eq := InStr(A_LoopField, "=")
        if (eq <= 0)
            continue
        k := SubStr(A_LoopField, 1, eq - 1)
        v := SubStr(A_LoopField, eq + 1)
        obj[k] := v
    }
    return obj
}

CockpitState_Read() {
    state := { "Schema": {}, "Global": {}, "Eta": {}, "Queues": {}
        , "Throughput": {}, "ModeStats": {}, "Runtime": {}, "Events": {}
        , "Alerts": {}, "Main": {}, "Instances": [] }

    path := CockpitState_Path()
    if (!FileExist(path))
        return state

    parsed := CockpitState_ParseFile(path)
    for secName, secData in parsed {
        if (state.HasKey(secName) && secName != "Instances")
            state[secName] := secData
    }

    instancesConfigured := state["Global"].HasKey("instancesConfigured")
        ? (state["Global"]["instancesConfigured"] + 0) : 0

    Loop, % instancesConfigured {
        sec := "Instance:" . A_Index
        if (parsed.HasKey(sec) && parsed[sec].Count() > 0)
            state["Instances"].Push(parsed[sec])
    }

    return state
}

; Whole-file INI parse in one FileRead: every IniRead/GetSection call reopens
; and rescans the entire file, so per-section reads cost O(sections * filesize)
; per tick. Returns { sectionName: { key: value } }. Quoted values are kept
; verbatim (no producer of these files writes quotes).
CockpitState_ParseFile(path) {
    parsed := {}
    if (!FileExist(path))
        return parsed
    FileRead, content, %path%
    if (content = "")
        return parsed
    cur := ""
    Loop, Parse, content, `n, `r
    {
        line := Trim(A_LoopField)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        if (SubStr(line, 1, 1) = "[") {
            end := InStr(line, "]")
            if (end > 2) {
                cur := SubStr(line, 2, end - 2)
                if (!parsed.HasKey(cur))
                    parsed[cur] := {}
            }
            continue
        }
        if (cur = "")
            continue
        eq := InStr(line, "=")
        if (eq <= 0)
            continue
        parsed[cur][RTrim(SubStr(line, 1, eq - 1))] := LTrim(SubStr(line, eq + 1))
    }
    return parsed
}

; sec[key] with default for possibly-missing sections/keys from CockpitState_ParseFile.
CockpitState_SecGet(sec, key, def := "") {
    return (IsObject(sec) && sec.HasKey(key)) ? sec[key] : def
}

;-------------------------------------------------------------------------------
; Writer builder
;-------------------------------------------------------------------------------
CockpitState_NewBuilder() {
    return { "buf": "", "currentSection": "" }
}

CockpitState_AddSection(builder, name) {
    if (builder["buf"] != "")
        builder["buf"] .= "`r`n"
    builder["buf"] .= "[" . name . "]`r`n"
    builder["currentSection"] := name
}

CockpitState_AddKey(builder, key, value) {
    if (value = "")
        value := ""
    builder["buf"] .= key . "=" . value . "`r`n"
}

CockpitState_AddKeyValues(builder, kvObj) {
    for k, v in kvObj
        CockpitState_AddKey(builder, k, v)
}

CockpitState_Commit(builder) {
    return CockpitState_CommitTo(builder, CockpitState_Path())
}

; Atomic whole-file write (.tmp -> rename) of a builder to any INI path.
; One disk write per commit vs one full rewrite+flush per IniWrite call.
CockpitState_CommitTo(builder, path) {
    tmpPath := path . ".tmp"

    SplitPath, path,, dir
    if (!FileExist(dir))
        FileCreateDir, %dir%

    if (FileExist(tmpPath))
        FileDelete, %tmpPath%

    ; UTF-16 LE with BOM: compatible with Windows native INI API (which is
    ; what AHK's IniRead uses under the hood).
    f := FileOpen(tmpPath, "w", "UTF-16")
    if (!f) {
        return 0
    }
    f.Write(builder["buf"])
    f.Close()

    if (FileExist(path))
        FileDelete, %path%
    FileMove, %tmpPath%, %path%, 1
    if (ErrorLevel) {
        return 0
    }
    return 1
}

;-------------------------------------------------------------------------------
; Lock (optional - used only if the writer ever becomes multi-process)
;-------------------------------------------------------------------------------
CockpitState_AcquireLock(timeoutMs := 5000) {
    lockName := "Global\PTCGPB_CockpitState"
    hMutex := DllCall("CreateMutex", "Ptr", 0, "Int", false, "Str", lockName, "Ptr")
    if (!hMutex)
        return 0
    waitResult := DllCall("WaitForSingleObject", "Ptr", hMutex, "UInt", timeoutMs, "UInt")
    if (waitResult != 0 && waitResult != 0x80) {
        DllCall("CloseHandle", "Ptr", hMutex)
        return 0
    }
    return hMutex
}

CockpitState_ReleaseLock(hMutex) {
    if (!hMutex)
        return
    DllCall("ReleaseMutex", "Ptr", hMutex)
    DllCall("CloseHandle", "Ptr", hMutex)
}
