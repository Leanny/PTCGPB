;===============================================================================
; Common.ahk - Shared helpers for the AHK v1 fallback helpers
;===============================================================================
; Strings, files, local/UTC time math, SHA-256, file locks, HTTP downloads,
; cardmap.json lookups and a small clap-style command line parser.
;===============================================================================

;-------------------------------------------------------------------------------
; Strings
;-------------------------------------------------------------------------------

; Exact, case-sensitive equality. AHK's "==" compares numeric-looking strings
; as numbers, which is wrong for IDs such as device accounts.
S_Eq(a, b) {
    if (StrLen(a) != StrLen(b))
        return false
    return a = "" || InStr(a, b, true) = 1
}

; Ordinal (code unit) comparison like Rust's str::cmp. Returns <0, 0 or >0.
S_Cmp(a, b) {
    return DllCall("msvcrt\wcscmp", "WStr", a, "WStr", b, "CDecl Int")
}

S_StartsWith(s, prefix) {
    return prefix = "" || InStr(s, prefix, true) = 1
}

S_EndsWith(s, suffix) {
    n := StrLen(suffix)
    if (n = 0)
        return true
    if (n > StrLen(s))
        return false
    return S_Eq(SubStr(s, 1 - n), suffix)
}

; Rust str::trim (Unicode whitespace).
S_Trim(s) {
    return RegExReplace(s, "^\s+|\s+$")
}

S_Lower(s) {
    return Format("{:L}", s)
}

S_IsDigits(s) {
    return s != "" && RegExMatch(s, "^[0-9]+$")
}

; Stable merge sort. cmp is a function object returning <0, 0 or >0.
Arr_Sort(arr, cmp) {
    n := arr.Length()
    if (n < 2)
        return arr
    src := arr.Clone()
    dst := []
    width := 1
    while (width < n) {
        i := 1
        while (i <= n) {
            mid := Min(i + width, n + 1)
            hi := Min(i + 2 * width, n + 1)
            a := i, b := mid, k := i
            while (a < mid && b < hi) {
                if (cmp.Call(src[b], src[a]) < 0)
                    dst[k++] := src[b++]
                else
                    dst[k++] := src[a++]
            }
            while (a < mid)
                dst[k++] := src[a++]
            while (b < hi)
                dst[k++] := src[b++]
            i += 2 * width
        }
        tmp := src, src := dst, dst := tmp
        width *= 2
    }
    Loop, %n%
        arr[A_Index] := src[A_Index]
    return arr
}

Cmp_Ordinal(a, b) {
    return S_Cmp(a, b)
}

;-------------------------------------------------------------------------------
; Console
;-------------------------------------------------------------------------------

StdOut(text) {
    try FileAppend, %text%`n, *
}

StdErr(text) {
    try FileAppend, %text%`n, **
}

;-------------------------------------------------------------------------------
; Paths and files
;-------------------------------------------------------------------------------

Path_Full(path) {
    if (path = "")
        path := "."
    size := DllCall("GetFullPathNameW", "WStr", path, "UInt", 0, "Ptr", 0, "Ptr", 0, "UInt")
    if (!size)
        return path
    VarSetCapacity(buf, size * 2 + 2, 0)
    DllCall("GetFullPathNameW", "WStr", path, "UInt", size + 1, "Ptr", &buf, "Ptr", 0, "UInt")
    full := StrGet(&buf, "UTF-16")
    if (StrLen(full) > 3)
        full := RTrim(full, "\")
    return full
}

Path_Name(path) {
    SplitPath, path, name
    return name
}

Path_Dir(path) {
    SplitPath, path,, dir
    return dir
}

; Rust Path::extension() (without the dot), "" when there is none.
Path_Ext(path) {
    name := Path_Name(path)
    p := InStr(name, ".", true, 0)
    if (p <= 1)
        return ""
    return SubStr(name, p + 1)
}

; Rust Path::file_stem()
Path_Stem(path) {
    name := Path_Name(path)
    p := InStr(name, ".", true, 0)
    if (p <= 1)
        return name
    return SubStr(name, 1, p - 1)
}

; Rust Path::with_extension(ext)
Path_WithExt(path, ext) {
    dir := Path_Dir(path)
    stem := Path_Stem(path)
    return (dir != "" ? dir . "\" : "") . stem . "." . ext
}

; Rust Path::starts_with on canonical paths (component-wise, case-insensitive).
Path_IsWithin(path, parent) {
    p := S_Lower(Path_Full(path))
    q := S_Lower(Path_Full(parent))
    return p == q || InStr(p, RTrim(q, "\") . "\", true) = 1
}

File_Exists(path) {
    return FileExist(path) != ""
}

File_IsDir(path) {
    return InStr(FileExist(path), "D") > 0
}

File_IsFile(path) {
    attr := FileExist(path)
    return attr != "" && !InStr(attr, "D")
}

; Note: inside a try block (which covers the whole run of these helpers) AHK v1
; commands that set ErrorLevel throw instead, so expected failures are caught.
File_Size(path) {
    try {
        FileGetSize, size, %path%
        return size + 0
    }
    return J_N(0)
}

Dir_Create(dir) {
    if (dir = "" || File_IsDir(dir))
        return
    FileCreateDir, %dir%
    if (ErrorLevel && !File_IsDir(dir))
        throw Exception("Could not create directory " . dir)
}

; Reads a whole file as UTF-8 (BOM stripped). Throws when it cannot be opened.
File_ReadUtf8(path) {
    f := FileOpen(path, "r", "UTF-8")
    if (!IsObject(f))
        throw Exception("Could not read " . path)
    text := f.Read()
    f.Close()
    if (SubStr(text, 1, 1) = Chr(0xFEFF))
        text := SubStr(text, 2)
    return text
}

; Writes text as UTF-8 without BOM, no line ending translation (fs::write).
File_WriteUtf8(path, ByRef text) {
    Dir_Create(Path_Dir(path))
    f := FileOpen(path, "w", "UTF-8-RAW")
    if (!IsObject(f))
        throw Exception("Could not write " . path)
    f.Write(text)
    f.Close()
}

File_AppendUtf8(path, text) {
    f := FileOpen(path, "a", "UTF-8-RAW")
    if (!IsObject(f))
        return false
    f.Write(text)
    f.Close()
    return true
}

; fs::rename - replaces an existing destination file.
File_Rename(from, to) {
    if (!DllCall("MoveFileExW", "WStr", from, "WStr", to, "UInt", 0x3))
        throw Exception("Could not move " . from . " to " . to . " (error " . A_LastError . ")")
}

; Write to "<path>.<tmpExt>" first and rename over the target.
File_WriteAtomic(path, ByRef text, tmpPath := "") {
    if (tmpPath = "")
        tmpPath := path . ".tmp"
    File_WriteUtf8(tmpPath, text)
    File_Rename(tmpPath, path)
}

File_Delete(path) {
    if (File_IsFile(path))
        try FileDelete, %path%
}

; Removes a file or a directory tree; missing paths are fine.
Path_Remove(path) {
    attr := FileExist(path)
    if (attr = "")
        return
    if (InStr(attr, "D")) {
        FileRemoveDir, %path%, 1
        if (ErrorLevel && File_IsDir(path))
            throw Exception("Could not remove directory " . path)
    } else {
        FileDelete, %path%
        if (ErrorLevel && File_Exists(path))
            throw Exception("Could not remove file " . path)
    }
}

; Lists directory entries in the same order as Rust's fs::read_dir.
; mode: "F" files, "D" directories, "FD" both. Returns full paths.
Dir_List(dir, mode := "F") {
    out := []
    if (!File_IsDir(dir))
        return out
    Loop, Files, %dir%\*, %mode%
        out.Push(A_LoopFileFullPath)
    return out
}

; Directory files with the given extension (case-insensitive), read_dir order.
Dir_ListExt(dir, ext) {
    out := []
    for _, path in Dir_List(dir, "F")
        if (Path_Ext(path) = ext)
            out.Push(path)
    return out
}

; Last write time as YYYYMMDDHH24MISS in local time, "" when unavailable.
File_ModifiedLocal(path) {
    try {
        FileGetTime, t, %path%, M
        return t
    }
    return ""
}

; Last write time in nanoseconds since the Unix epoch (Rust SystemTime) and size.
File_Stat(path, ByRef nanos, ByRef size) {
    VarSetCapacity(data, 36, 0)
    if (!DllCall("GetFileAttributesExW", "WStr", path, "Int", 0, "Ptr", &data))
        return false
    ft := NumGet(data, 20, "Int64")
    nanos := (ft - 116444736000000000) * 100
    size := (NumGet(data, 28, "UInt") << 32) | NumGet(data, 32, "UInt")
    return true
}

; Exclusive lock file created with CREATE_NEW (same protocol as the Rust
; helpers). Stale locks older than 60 s of waiting are removed.
Lock_Acquire(lockPath, writePid := false) {
    started := A_TickCount
    Loop {
        h := DllCall("CreateFileW", "WStr", lockPath, "UInt", 0x40000000, "UInt", 0, "Ptr", 0
            , "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
        if (h != -1) {
            if (writePid) {
                text := "pid=" . DllCall("GetCurrentProcessId") . "`n"
                VarSetCapacity(buf, StrPut(text, "UTF-8"))
                n := StrPut(text, &buf, "UTF-8") - 1
                DllCall("WriteFile", "Ptr", h, "Ptr", &buf, "UInt", n, "UInt*", written, "Ptr", 0)
            }
            DllCall("CloseHandle", "Ptr", h)
            return lockPath
        }
        err := A_LastError
        if (err != 80 && err != 183)
            throw Exception("Could not create " . lockPath . " (error " . err . ")")
        if (A_TickCount - started >= 60000) {
            File_Delete(lockPath)
            started := A_TickCount
            continue
        }
        Sleep, 250
    }
}

Lock_Release(lockPath) {
    if (lockPath != "")
        File_Delete(lockPath)
}

;-------------------------------------------------------------------------------
; Time. Timestamps are YYYYMMDDHH24MISS strings, local unless named *Utc.
;-------------------------------------------------------------------------------

; chrono NaiveDateTime::parse_from_str(ts, "%Y%m%d%H%M%S")
Ts_IsValid(ts) {
    if (StrLen(ts) != 14 || !S_IsDigits(ts))
        return false
    if ts is not time
        return false
    return true
}

Ts_Add(ts, amount, unit := "Seconds") {
    EnvAdd, ts, %amount%, %unit%
    return ts
}

; a - b in seconds.
Ts_Diff(a, b) {
    EnvSub, a, %b%, Seconds
    return a
}

Ts__ToSystemTime(ts, ByRef st) {
    VarSetCapacity(st, 16, 0)
    NumPut(SubStr(ts, 1, 4), st, 0, "UShort")
    NumPut(SubStr(ts, 5, 2), st, 2, "UShort")
    NumPut(SubStr(ts, 7, 2), st, 6, "UShort")
    NumPut(SubStr(ts, 9, 2), st, 8, "UShort")
    NumPut(SubStr(ts, 11, 2), st, 10, "UShort")
    NumPut(SubStr(ts, 13, 2), st, 12, "UShort")
}

Ts__FromSystemTime(ByRef st) {
    return Format("{:04}{:02}{:02}{:02}{:02}{:02}"
        , NumGet(st, 0, "UShort"), NumGet(st, 2, "UShort"), NumGet(st, 6, "UShort")
        , NumGet(st, 8, "UShort"), NumGet(st, 10, "UShort"), NumGet(st, 12, "UShort"))
}

; Local wall-clock time -> UTC using the DST rules of that date, "" when the
; local time does not exist (spring forward) or is ambiguous (fall back) -
; chrono's Local.from_local_datetime(..).single() semantics.
; Like chrono, the gap is open at its start (02:00:00 on spring-forward day is
; still accepted with the old offset) and the overlap includes its end (03:00:00
; on fall-back day is rejected).
Ts_LocalToUtc(ts) {
    hour := SubStr(ts, 1, 10)
    if (SubStr(ts, 11, 4) == "0000") {
        prev := Ts__HourInfo(SubStr(Ts_Add(hour . "0000", -1, "Hours"), 1, 10))
        if (prev.status = "ambiguous")
            return ""
        cur := Ts__HourInfo(hour)
        if (cur.status = "gap")
            return (prev.status = "ok") ? Ts_Add(ts, prev.offset, "Seconds") : ""
    }
    info := Ts__HourInfo(hour)
    return (info.status = "ok") ? Ts_Add(ts, info.offset, "Seconds") : ""
}

; Classifies a local hour (YYYYMMDDHH) as "ok" (with its UTC offset in
; seconds), "gap", "ambiguous" or "invalid". The UTC offset only changes on hour
; boundaries, so results are cached; pull histories convert tens of thousands
; of timestamps.
Ts__HourInfo(hour) {
    static cache := {}
    key := "h" . hour
    if (cache.HasKey(key))
        return cache[key]
    info := {status: "invalid", offset: ""}
    probe := hour . "3000"
    Ts__ToSystemTime(probe, local)
    VarSetCapacity(utc, 16, 0)
    if (DllCall("TzSpecificLocalTimeToSystemTime", "Ptr", 0, "Ptr", &local, "Ptr", &utc)) {
        u := Ts__FromSystemTime(utc)
        if (!S_Eq(Ts_UtcToLocal(u), probe)) {
            info.status := "gap"
        } else {
            info.status := "ok"
            for _, shift in [-3600, 3600, -1800, 1800]
                if (S_Eq(Ts_UtcToLocal(Ts_Add(u, shift, "Seconds")), probe))
                    info.status := "ambiguous"
            if (info.status = "ok")
                info.offset := Ts_Diff(u, probe)
        }
    }
    cache[key] := info
    return info
}

Ts_UtcToLocal(ts) {
    static offsets := {}
    hour := "h" . SubStr(ts, 1, 10)
    if (!offsets.HasKey(hour)) {
        Ts__ToSystemTime(ts, utc)
        VarSetCapacity(local, 16, 0)
        if (DllCall("SystemTimeToTzSpecificLocalTime", "Ptr", 0, "Ptr", &utc, "Ptr", &local))
            offsets[hour] := Ts_Diff(Ts__FromSystemTime(local), ts)
        else
            offsets[hour] := ""
    }
    offset := offsets[hour]
    return (offset = "") ? "" : Ts_Add(ts, offset, "Seconds")
}

; Unix seconds -> UTC timestamp, "" when out of range.
Ts_FromUnix(seconds) {
    if (seconds < -11644473600 || seconds > 253402300799)
        return ""
    return Ts_Add("19700101000000", seconds, "Seconds")
}

; Rust Duration::num_hours (truncates toward zero).
Ts_TruncDiv(a, b) {
    q := Abs(a) // b
    return (a < 0) ? -q : q
}

Ts_Format(ts, fmt) {
    FormatTime, out, %ts%, %fmt%
    return out
}

; "2026-10-05T18:00:00.123+00:00" (chrono to_rfc3339 for Utc::now()).
Ts_NowRfc3339Utc() {
    t := A_NowUTC
    return Ts_Format(t, "yyyy-MM-ddTHH:mm:ss") . "." . A_MSec . "+00:00"
}

;-------------------------------------------------------------------------------
; Hashing
;-------------------------------------------------------------------------------

; Lowercase hex SHA-256 of the UTF-8 bytes of text.
Sha256Hex(ByRef text) {
    static hAlg := 0
    if (!hAlg && DllCall("bcrypt\BCryptOpenAlgorithmProvider", "Ptr*", hAlg, "WStr", "SHA256", "Ptr", 0, "UInt", 0) != 0)
        throw Exception("Could not open SHA256 provider")
    len := StrPut(text, "UTF-8") - 1
    VarSetCapacity(buf, len + 1, 0)
    StrPut(text, &buf, "UTF-8")
    VarSetCapacity(hash, 32, 0)
    if (DllCall("bcrypt\BCryptHash", "Ptr", hAlg, "Ptr", 0, "UInt", 0, "Ptr", &buf, "UInt", len, "Ptr", &hash, "UInt", 32) != 0)
        throw Exception("SHA256 failed")
    hex := ""
    Loop, 32
        hex .= Format("{:02x}", NumGet(hash, A_Index - 1, "UChar"))
    return hex
}

;-------------------------------------------------------------------------------
; HTTP
;-------------------------------------------------------------------------------

Http_NewRequest() {
    whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
    proxyEnabled := 0, proxyServer := ""
    try RegRead, proxyEnabled, HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings, ProxyEnable
    try RegRead, proxyServer, HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings, ProxyServer
    if (proxyEnabled && proxyServer != "")
        whr.SetProxy(2, proxyServer)
    return whr
}

; Downloads url into path. Returns true on HTTP 2xx and a written file.
Http_DownloadToFile(url, path, minBytes := 1) {
    try {
        whr := Http_NewRequest()
        whr.Open("GET", url, true)
        whr.Send()
        whr.WaitForResponse(120)
        if (whr.Status < 200 || whr.Status >= 300)
            return false
        return Http_SaveBody(whr.ResponseBody, path, minBytes)
    } catch {
        return false
    }
}

; Saves a WinHttp ResponseBody (byte SAFEARRAY) when it has at least minBytes.
Http_SaveBody(body, path, minBytes := 1) {
    size := body.MaxIndex() + 1
    if (size < minBytes)
        return false
    pData := NumGet(ComObjValue(body) + 8 + A_PtrSize, "Ptr")
    Dir_Create(Path_Dir(path))
    f := FileOpen(path, "w")
    if (!IsObject(f))
        return false
    f.RawWrite(pData + 0, size)
    f.Close()
    return true
}

;-------------------------------------------------------------------------------
; cardmap.json
;-------------------------------------------------------------------------------

CardMap_Url() {
    return "https://leanny.github.io/pocket_tcg_resources/data/cardmap.json"
}

; Modified less than an hour ago.
CardMap_IsFresh(path) {
    if (!File_Stat(path, nanos, size))
        return false
    ageSeconds := Ts_Diff(A_NowUTC, Ts_FromUnix(nanos // 1000000000))
    return ageSeconds >= 0 && ageSeconds < 3600
}

; Same locking protocol as the Rust helpers ("cardmap.json.download.lock").
CardMap_Download(path, force) {
    Dir_Create(Path_Dir(path))
    lock := Lock_Acquire(Path_WithExt(path, "json.download.lock"), true)
    try {
        if (!force && File_Exists(path) && File_Size(path) > 0)
            return true
        if (force)
            File_Delete(path)
        tmp := path . ".part"
        if (!Http_DownloadToFile(CardMap_Url(), tmp, 2))
            throw Exception("Could not download cardmap.json from " . CardMap_Url())
        text := File_ReadUtf8(tmp)
        if (!RegExMatch(text, "^\s*[\[{]") || !RegExMatch(text, "[\]}]\s*$")) {
            File_Delete(tmp)
            throw Exception("Downloaded cardmap.json was not valid JSON")
        }
        File_Rename(tmp, path)
        return true
    } finally {
        Lock_Release(lock)
    }
}

; Text of the entry object for one card id, or "" when the id is not a key of
; the top-level object. cardmap.json is a flat {"<cardId>": {...}} object, so a
; targeted regex is far faster in AHK than parsing 500 KB of JSON.
CardMap_EntryBody(ByRef text, cardId) {
    if (RegExMatch(text, "S)""\Q" . cardId . "\E""\s*:\s*\{([^{}]*)\}", m))
        return m1
    return ""
}

; String field of an entry body, "" when missing or not a string.
CardMap_BodyStr(ByRef body, field) {
    if (RegExMatch(body, "S)""\Q" . field . "\E""\s*:\s*(""[^""\\]*+(?:\\.[^""\\]*+)*+"")", m))
        return Json__Unescape(m1)
    return ""
}

; Integer field of an entry body, "" when missing or not an integer.
CardMap_BodyInt(ByRef body, field) {
    if (RegExMatch(body, "S)""\Q" . field . "\E""\s*:\s*(-?\d+)\s*(?:,|$)", m))
        return m1 + 0
    return ""
}

;-------------------------------------------------------------------------------
; Command line (clap-like: "--name value", "--name=value", "--flag")
;-------------------------------------------------------------------------------

; spec: {values: "a b", flags: "c d", positional: N}
; Returns {opts: {name: value}, flags: {name: true}, pos: [...]}. Option names
; are stored with "-" replaced by "_". Throws on unknown or malformed options.
Cli_Parse(args, startIndex, spec) {
    values := {}, flags := {}
    for _, name in StrSplit(spec.values, " ", " ")
        if (name != "")
            values[name] := true
    for _, name in StrSplit(spec.flags, " ", " ")
        if (name != "")
            flags[name] := true

    result := {opts: {}, flags: {}, pos: []}
    i := startIndex
    n := args.Length()
    while (i <= n) {
        arg := args[i]
        if (SubStr(arg, 1, 2) = "--" && StrLen(arg) > 2) {
            name := SubStr(arg, 3)
            value := ""
            hasInline := false
            if (p := InStr(name, "=")) {
                value := SubStr(name, p + 1)
                name := SubStr(name, 1, p - 1)
                hasInline := true
            }
            key := StrReplace(name, "-", "_")
            if (flags.HasKey(name)) {
                if (hasInline)
                    throw Exception("unexpected value for flag '--" . name . "'")
                result.flags[key] := true
            } else if (values.HasKey(name)) {
                if (!hasInline) {
                    if (i = n)
                        throw Exception("a value is required for '--" . name . "' but none was supplied")
                    i += 1
                    value := args[i]
                }
                if (result.opts.HasKey(key))
                    throw Exception("the argument '--" . name . "' cannot be used multiple times")
                result.opts[key] := value
            } else {
                throw Exception("unexpected argument '" . arg . "' found")
            }
        } else {
            result.pos.Push(arg)
        }
        i += 1
    }
    return result
}

Cli_Require(cli, names) {
    for _, name in StrSplit(names, " ", " ") {
        if (name != "" && !cli.opts.HasKey(StrReplace(name, "-", "_")))
            throw Exception("the following required arguments were not provided: --" . name)
    }
}
