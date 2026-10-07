; ====================================================================
; TestRecorder - records frames and detection results for the
; detection regression tests (Scripts\DetectionTests.ahk).
;
; Enable via Tools & System > Test recording..., or in Settings.ini:
;   [ToolsAndSystem]
;   testRecording=1
;   testRecordingDir=          ; optional, default <bot folder>\Screenshots\recorded
;   testRecordingIntervalMs=10000
;   testRecordingMaxFrames=3000
; Instances read these settings once, when they start.
;
; Output layout (shared by all instances):
;   frames\<id>.png            haystack bitmaps, deduplicated by pixel hash
;   sessions\<time>_<script>.jsonl
;       one JSON object per line: "session", "search" or "analysis" events
;
; A search is only logged when its result changed since the last search
; with the same needle/region/caller, or after testRecordingIntervalMs.
; Card analyses are always logged; the rarity border searches they consist
; of are not logged separately.
; ====================================================================

TestRec_IsEnabled() {
    global botConfig, session, g_TestRec
    if (IsObject(g_TestRec))
        return g_TestRec.enabled
    if (!IsObject(botConfig))
        return false

    g_TestRec := {enabled: false}
    if (!botConfig.get("testRecording"))
        return false

    rootDir := TestRec_RootDir()
    FileCreateDir, %rootDir%\frames
    FileCreateDir, %rootDir%\sessions

    scriptName := IsObject(session) ? session.get("scriptName") : ""
    if (scriptName = "")
        scriptName := StrReplace(A_ScriptName, ".ahk")

    intervalMs := botConfig.get("testRecordingIntervalMs")
    maxFrames := botConfig.get("testRecordingMaxFrames")

    FormatTime, stamp,, yyyyMMdd_HHmmss
    g_TestRec := {enabled: true
        , framesDir: rootDir . "\frames"
        , sessionFile: rootDir . "\sessions\" . stamp . "_" . scriptName . ".jsonl"
        , intervalMs: (intervalMs = "" ? 10000 : intervalMs + 0)
        , maxFrames: (maxFrames = "" ? 3000 : maxFrames + 0)
        , frameCount: 0
        , savedFrames: {}
        , lastByKey: {}
        , lastYBias: 0}

    TestRec_WriteLine("{""type"":""session"",""script"":" . TestRec_JsonStr(scriptName)
        . ",""started"":" . TestRec_JsonStr(stamp) . "}")
    return true
}

; Recording folder from the settings, or the default <bot folder>\Screenshots\recorded.
TestRec_RootDir() {
    global botConfig
    rootDir := IsObject(botConfig) ? botConfig.get("testRecordingDir") : ""
    if (rootDir = "")
        rootDir := getScriptBaseFolder() . "\Screenshots\recorded"
    return RTrim(rootDir, "\/")
}

; Called by Gdip_ImageSearch_wbb after every search. x1..y2 are the effective
; search coordinates (title bar bias already applied).
TestRec_OnSearch(pHaystack, pNeedle, x1, y1, x2, y2, yBias, variation, trans, searchDirection, instances, result, outputList) {
    global g_TestRec
    if (!TestRec_IsEnabled())
        return

    rec := g_TestRec
    rec.lastYBias := yBias
    ; Stack: TestRec_Caller, TestRec_OnSearch, Gdip_ImageSearch_wbb, <searching function>
    caller := TestRec_Caller(4)
    ; Rarity border searches are covered by the "analysis" event of the same frame.
    if (InStr(caller, "RarityBorder.") = 1)
        return
    needle := TestRec_NeedleRelPath(pNeedle.Path)
    key := needle . "|" . x1 . "," . y1 . "," . x2 . "," . y2 . "|" . variation . "|" . caller

    now := A_TickCount
    last := rec.lastByKey[key]
    if (IsObject(last) && last.result = result && now - last.tick < rec.intervalMs)
        return

    frameId := TestRec_EnsureFrame(pHaystack)
    if (frameId = "")
        return
    rec.lastByKey[key] := {result: result, tick: now}

    TestRec_WriteLine("{""type"":""search"",""frame"":" . TestRec_JsonStr(frameId)
        . ",""needle"":" . TestRec_JsonStr(needle)
        . ",""region"":[" . x1 . "," . y1 . "," . x2 . "," . y2 . "]"
        . ",""yBias"":" . yBias
        . ",""variation"":" . variation
        . ",""trans"":" . TestRec_JsonStr(trans)
        . ",""direction"":" . searchDirection
        . ",""instances"":" . instances
        . ",""result"":" . result
        . ",""positions"":" . TestRec_JsonStr(outputList)
        . ",""caller"":" . TestRec_JsonStr(caller) . "}")
}

; Called by AnalysisBorder with the frame the card rarities were read from.
TestRec_OnAnalysis(pBitmap, totalCardsInPack, packInfo) {
    global g_TestRec
    if (!TestRec_IsEnabled())
        return

    frameId := TestRec_EnsureFrame(pBitmap)
    if (frameId = "")
        return

    slots := ""
    Loop, % totalCardsInPack
        slots .= (A_Index > 1 ? "," : "") . TestRec_JsonStr(packInfo["CardSlot"][A_Index])

    TestRec_WriteLine("{""type"":""analysis"",""frame"":" . TestRec_JsonStr(frameId)
        . ",""cards"":" . totalCardsInPack
        . ",""yBias"":" . g_TestRec.lastYBias
        . ",""slots"":[" . slots . "]}")
}

; Saves the bitmap once and returns its id: two CRC32s (first and second half
; of the pixel data) plus the size. Returns "" when the frame limit is reached.
TestRec_EnsureFrame(pBitmap) {
    global g_TestRec
    rec := g_TestRec

    Gdip_GetImageDimensions(pBitmap, w, h)
    if (!w || !h)
        return ""
    if (Gdip_LockBits(pBitmap, 0, 0, w, h, stride, scan0, bitmapData, 1))
        return ""
    total := Abs(stride) * h
    half := total // 2
    crcA := DllCall("ntdll\RtlComputeCrc32", "UInt", 0, "Ptr", scan0, "UInt", half, "UInt")
    crcB := DllCall("ntdll\RtlComputeCrc32", "UInt", 0, "Ptr", scan0 + half, "UInt", total - half, "UInt")
    Gdip_UnlockBits(pBitmap, bitmapData)

    frameId := Format("{:08x}{:08x}_{}x{}", crcA, crcB, w, h)
    if (rec.savedFrames.HasKey(frameId))
        return frameId

    framePath := rec.framesDir . "\" . frameId . ".png"
    if (!FileExist(framePath)) {
        if (rec.frameCount >= rec.maxFrames)
            return ""
        ; Write to a temp name first so parallel instances never see half-written files.
        tmpPath := rec.framesDir . "\" . frameId . "." . DllCall("GetCurrentProcessId") . ".tmp.png"
        if (Gdip_SaveBitmapToFile(pBitmap, tmpPath) != 0) {
            FileDelete, %tmpPath%
            return ""
        }
        FileMove, %tmpPath%, %framePath%
        if (ErrorLevel)
            FileDelete, %tmpPath%
        rec.frameCount += 1
    }
    rec.savedFrames[frameId] := true
    return frameId
}

; "FindOrLoseImage<CheckPack": the function that searched and the one that called it.
TestRec_Caller(depth) {
    names := ""
    Loop, 2 {
        what := Exception("", -(depth + A_Index - 1)).What
        if (what = "" || RegExMatch(what, "^-?\d+$"))
            break
        names .= (A_Index > 1 ? "<" : "") . what
    }
    return names
}

TestRec_NeedleRelPath(path) {
    path := StrReplace(path, "\", "/")
    if (pos := InStr(path, "/Needles/"))
        return SubStr(path, pos + 1)
    return path
}

TestRec_WriteLine(line) {
    global g_TestRec
    FileAppend, % line . "`n", % g_TestRec.sessionFile, UTF-8-RAW
}

TestRec_JsonStr(value) {
    value := StrReplace(value, "\", "\\")
    value := StrReplace(value, """", "\""")
    value := StrReplace(value, "`r", "\r")
    value := StrReplace(value, "`n", "\n")
    value := StrReplace(value, "`t", "\t")
    return """" . value . """"
}
