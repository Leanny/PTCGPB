; ====================================================================
; DetectionTests - replays recorded frames through the image detection
; code and reports every difference to the recorded results.
;
; Record data via Tools & System > Test recording... (see Include\TestRecorder.ahk).
;
; Usage:
;   AutoHotkey.exe DetectionTests.ahk [--data <dir>] [--update] [--draft-labels]
;                                     [--no-fullscan] [--ci]
;
;   --data <dir>     recording folder (default: ..\Screenshots\recorded)
;   --update         rewrite snapshots\fullscan.txt from the current results
;   --draft-labels   write labels.draft.txt for analysed frames without a label
;   --no-fullscan    skip the full needle scan
;   --ci             no message box; result only via stdout and exit code
;
; Checks:
;   search    recorded Gdip_ImageSearch calls must return the same result
;   analysis  AnalyzeBorderBitmap must classify the card slots the same way
;   label     AnalyzeBorderBitmap must match the hand-checked labels.txt
;   fullscan  every registered needle against every frame; compared with
;             snapshots\fullscan.txt (new frames are reported, not failed)
;
; Writes report.txt into the data folder. Exit code 1 on any failure.
; ====================================================================
#NoEnv
#SingleInstance, Off
SetBatchLines, -1
ListLines, Off

#Include %A_ScriptDir%\Include\
#Include Gdip_All.ahk
#Include Gdip_Imagesearch.ahk
global pToken := Gdip_Startup()
#Include Coords.ahk
#Include RarityBorder.ahk
#Include PackAnalysis.ahk

global g_ReplayYBias := 0

DetectionTests_Main()
ExitApp

DetectionTests_Main() {
    opts := DT_ParseArgs()
    dataDir := DT_FullPath(opts.data)
    if (!InStr(FileExist(dataDir), "D"))
        DT_Finish(opts, "Data folder not found: " . opts.data, 2)

    report := ""
    stats := {searches: 0, searchFailures: 0, analyses: 0, analysisFailures: 0
        , labels: 0, labelFailures: 0, fullscanFrames: 0, fullscanChanged: 0, fullscanNew: 0
        , missingFrames: 0, parseErrors: 0}

    frames := DT_LoadSessions(dataDir, stats, report)
    labels := DT_LoadLabels(dataDir . "\labels.txt", frames, report)
    snapshotPath := dataDir . "\snapshots\fullscan.txt"
    snapshot := DT_LoadSnapshot(snapshotPath)
    newSnapshot := ""
    draftLabels := ""

    frameTotal := frames.Count()
    frameIndex := 0
    for frameId, frame in frames {
        frameIndex += 1
        if (!opts.ci)
            ToolTip, % "Detection tests: frame " . frameIndex . " / " . frameTotal

        framePath := dataDir . "\frames\" . frameId . ".png"
        if (!FileExist(framePath)) {
            stats.missingFrames += 1
            report .= "MISSING  " . frameId . ".png`n"
            continue
        }
        pBitmap := Gdip_CreateBitmapFromFile(framePath)

        for i, s in frame.searches {
            stats.searches += 1
            failure := DT_ReplaySearch(pBitmap, s)
            if (failure != "") {
                stats.searchFailures += 1
                report .= "SEARCH   " . frameId . "  " . s.needle . " [" . DT_Join(s.region, ",") . "] from " . s.caller . ": " . failure . "`n"
            }
        }

        for i, a in frame.analyses {
            stats.analyses += 1
            g_ReplayYBias := a.yBias
            actual := DT_SlotsOf(AnalyzeBorderBitmap(pBitmap, a.cards), a.cards)
            expected := DT_Join(a.slots, ",")
            if (actual != expected) {
                stats.analysisFailures += 1
                report .= "ANALYSIS " . frameId . "  expected [" . expected . "] got [" . actual . "]`n"
            }
        }

        if (labels.HasKey(frameId)) {
            label := labels[frameId]
            stats.labels += 1
            g_ReplayYBias := (label.yBias != "") ? label.yBias : DT_FirstKey(frame.biases, 0)
            actual := DT_SlotsOf(AnalyzeBorderBitmap(pBitmap, label.cards), label.cards)
            if (actual != label.slots) {
                stats.labelFailures += 1
                report .= "LABEL    " . frameId . "  expected [" . label.slots . "] got [" . actual . "]`n"
            }
        } else if (opts.draftLabels && frame.analyses.Length() > 0) {
            a := frame.analyses[1]
            g_ReplayYBias := a.yBias
            slots := DT_SlotsOf(AnalyzeBorderBitmap(pBitmap, a.cards), a.cards)
            draftLabels .= frameId . " " . a.cards . " " . DT_MapSlots(slots, "", "-") . "`n"
        }

        if (opts.fullscan) {
            for bias in frame.biases {
                key := frameId . " " . bias
                hits := DT_FullScan(pBitmap, bias)
                newSnapshot .= key . " " . hits . "`n"
                stats.fullscanFrames += 1
                if (!snapshot.HasKey(key)) {
                    stats.fullscanNew += 1
                } else if (snapshot[key] != hits) {
                    stats.fullscanChanged += 1
                    report .= "FULLSCAN " . key . "  " . DT_DiffNames(snapshot[key], hits) . "`n"
                }
            }
        }

        Gdip_DisposeImage(pBitmap)
    }
    ToolTip

    if (opts.fullscan && opts.update) {
        FileCreateDir, %dataDir%\snapshots
        FileDelete, %snapshotPath%
        FileAppend, %newSnapshot%, %snapshotPath%, UTF-8-RAW
    }
    if (opts.draftLabels) {
        draftPath := dataDir . "\labels.draft.txt"
        FileDelete, %draftPath%
        FileAppend, %draftLabels%, %draftPath%, UTF-8-RAW
    }

    failures := stats.searchFailures + stats.analysisFailures + stats.labelFailures
        + stats.missingFrames + stats.parseErrors
    if (!opts.update)
        failures += stats.fullscanChanged

    summary := "Detection tests: " . (failures ? "FAILED" : "passed") . "`n"
        . "  frames      " . frameTotal . " (" . stats.missingFrames . " missing)`n"
        . "  searches    " . stats.searches . " replayed, " . stats.searchFailures . " failed`n"
        . "  analyses    " . stats.analyses . " replayed, " . stats.analysisFailures . " failed`n"
        . "  labels      " . stats.labels . " checked, " . stats.labelFailures . " failed`n"
        . "  fullscan    " . (opts.fullscan ? stats.fullscanFrames . " scanned, " . stats.fullscanChanged . " changed, " . stats.fullscanNew . " new" . (opts.update ? " (snapshot updated)" : (stats.fullscanNew ? " (run with --update to accept)" : "")) : "skipped") . "`n"
        . (stats.parseErrors ? "  parse errors " . stats.parseErrors . "`n" : "")

    reportPath := dataDir . "\report.txt"
    FileDelete, %reportPath%
    FileAppend, % summary . "`n" . report, %reportPath%, UTF-8-RAW

    DT_Finish(opts, summary . (report != "" ? "`nDetails: " . reportPath : ""), failures ? 1 : 0)
}

; ---------------------------------------------------------------- replay

DT_ReplaySearch(pBitmap, s) {
    needlePath := A_ScriptDir . "\" . StrReplace(s.needle, "/", "\")
    if (!FileExist(needlePath))
        return "needle image missing"
    pNeedle := GetNeedle(needlePath)
    region := s.region
    result := Gdip_ImageSearch(pBitmap, pNeedle.needle, positions
        , region[1], region[2], region[3], region[4]
        , s.variation, s.trans, s.direction, s.instances)
    if (result != s.result)
        return "expected result " . s.result . " got " . result
    if (result > 0 && positions != s.positions)
        return "expected position " . StrReplace(s.positions, "`n", " ") . " got " . StrReplace(positions, "`n", " ")
    return ""
}

; Space separated names of all registered needles found in the frame.
DT_FullScan(pBitmap, yBias) {
    global needlesDict
    hits := ""
    for name, needleObj in needlesDict.needles {
        c := needleObj.coords
        if (!c.isValid)
            continue
        needlePath := A_ScriptDir . "\Needles\" . needleObj.imageName . ".png"
        if (!FileExist(needlePath))
            continue
        pNeedle := GetNeedle(needlePath)
        if (Gdip_ImageSearch(pBitmap, pNeedle.needle, positions, c.startX, c.startY + yBias, c.endX, c.endY + yBias, 20) > 0)
            hits .= (hits = "" ? "" : " ") . name
    }
    return hits
}

; Same as the bot's wrapper, but the title bar bias comes from the recording.
Gdip_ImageSearch_wbb(pBitmapHaystack, pNeedle, ByRef OutputList=""
    , OuterX1=0, OuterY1=0, OuterX2=0, OuterY2=0, Variation=0, Trans=""
    , SearchDirection=1, Instances=1, LineDelim="`n", CoordDelim=",") {
    global g_ReplayYBias
    return Gdip_ImageSearch(pBitmapHaystack, pNeedle.needle, OutputList
        , OuterX1, OuterY1 + g_ReplayYBias, OuterX2, OuterY2 + g_ReplayYBias
        , Variation, Trans, SearchDirection, Instances, LineDelim, CoordDelim)
}

GetNeedle(Path) {
    static NeedleBitmaps := {}
    if (!NeedleBitmaps.HasKey(Path))
        NeedleBitmaps[Path] := {Path: Path, Name: RegExReplace(Path, ".*\\"), needle: Gdip_CreateBitmapFromFile(Path)}
    return NeedleBitmaps[Path]
}

; ---------------------------------------------------------------- loading

; Returns frameId -> {searches: [], analyses: [], biases: {yBias: true}}
DT_LoadSessions(dataDir, stats, ByRef report) {
    frames := {}
    seen := {}
    Loop, Files, %dataDir%\sessions\*.jsonl
    {
        sessionName := A_LoopFileName
        FileRead, text, *P65001 %A_LoopFileFullPath%
        Loop, Parse, text, `n, `r
        {
            line := Trim(A_LoopField, " `t" . Chr(0xFEFF))
            if (line = "")
                continue
            try {
                event := Json_Parse(line)
            } catch e {
                stats.parseErrors += 1
                report .= "PARSE    " . sessionName . ":" . A_Index . "  " . e.Message . "`n"
                continue
            }
            if (event.type != "search" && event.type != "analysis")
                continue
            ; The same recorded call can appear in several sessions; replay it once.
            if (seen.HasKey(line))
                continue
            seen[line] := true

            frame := DT_Frame(frames, event.frame)
            frame.biases[event.yBias + 0] := true
            if (event.type = "search")
                frame.searches.Push(event)
            else
                frame.analyses.Push(event)
        }
    }
    return frames
}

; labels.txt: "<frameId> <cards> <slot,slot,...> [yBias]", "-" for an empty slot.
DT_LoadLabels(path, frames, ByRef report) {
    labels := {}
    if (!FileExist(path))
        return labels
    FileRead, text, *P65001 %path%
    Loop, Parse, text, `n, `r
    {
        line := Trim(A_LoopField, " `t" . Chr(0xFEFF))
        if (line = "" || SubStr(line, 1, 1) = "#")
            continue
        parts := StrSplit(RegExReplace(line, "\s+", " "), " ")
        if (parts.Length() < 3) {
            report .= "PARSE    labels.txt:" . A_Index . "  expected <frameId> <cards> <slots>`n"
            continue
        }
        labels[parts[1]] := {cards: parts[2] + 0, slots: DT_MapSlots(parts[3], "-", ""), yBias: parts[4]}
        DT_Frame(frames, parts[1])
    }
    return labels
}

DT_LoadSnapshot(path) {
    snapshot := {}
    if (!FileExist(path))
        return snapshot
    FileRead, text, *P65001 %path%
    Loop, Parse, text, `n, `r
    {
        if (!RegExMatch(A_LoopField, "^(\S+ -?\d+) ?(.*)$", m))
            continue
        snapshot[m1] := m2
    }
    return snapshot
}

DT_Frame(frames, frameId) {
    if (!frames.HasKey(frameId))
        frames[frameId] := {searches: [], analyses: [], biases: {}}
    return frames[frameId]
}

; ---------------------------------------------------------------- helpers

DT_ParseArgs() {
    opts := {data: A_ScriptDir . "\..\Screenshots\recorded", update: false, draftLabels: false, fullscan: true, ci: false}
    i := 1
    while (i <= A_Args.Length()) {
        arg := A_Args[i]
        if (arg = "--data")
            opts.data := A_Args[++i]
        else if (arg = "--update")
            opts.update := true
        else if (arg = "--draft-labels")
            opts.draftLabels := true
        else if (arg = "--no-fullscan")
            opts.fullscan := false
        else if (arg = "--ci")
            opts.ci := true
        else
            DT_Finish(opts, "Unknown argument: " . arg, 2)
        i += 1
    }
    return opts
}

DT_Finish(opts, message, exitCode) {
    FileAppend, % message . "`n", *
    if (!opts.ci)
        MsgBox, % (exitCode ? 0x10 : 0x40), Detection tests, %message%
    ExitApp, %exitCode%
}

DT_FullPath(path) {
    VarSetCapacity(buffer, 2048 * 2, 0)
    DllCall("GetFullPathNameW", "WStr", path, "UInt", 2048, "Ptr", &buffer, "Ptr", 0)
    return RTrim(StrGet(&buffer, "UTF-16"), "\")
}

DT_SlotsOf(packInfo, cards) {
    slots := ""
    Loop, % cards
        slots .= (A_Index > 1 ? "," : "") . packInfo["CardSlot"][A_Index]
    return slots
}

; Replaces whole slot values, e.g. "" <-> "-" for empty slots in labels.txt.
DT_MapSlots(slots, from, to) {
    out := ""
    Loop, Parse, slots, `,
        out .= (A_Index > 1 ? "," : "") . (A_LoopField == from ? to : A_LoopField)
    return out
}

DT_Join(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i > 1 ? sep : "") . v
    return out
}

DT_FirstKey(obj, default) {
    for key in obj
        return key
    return default
}

DT_DiffNames(before, after) {
    beforeSet := {}, afterSet := {}, diff := ""
    Loop, Parse, before, %A_Space%
        beforeSet[A_LoopField] := true
    Loop, Parse, after, %A_Space%
        afterSet[A_LoopField] := true
    for name in afterSet
        if (!beforeSet.HasKey(name))
            diff .= " +" . name
    for name in beforeSet
        if (!afterSet.HasKey(name))
            diff .= " -" . name
    return LTrim(diff)
}

; ---------------------------------------------------------------- JSON

Json_Parse(text) {
    pos := 1
    value := Json_Value(text, pos)
    Json_SkipWs(text, pos)
    if (pos <= StrLen(text))
        throw Exception("unexpected data at column " . pos)
    return value
}

Json_Value(ByRef text, ByRef pos) {
    Json_SkipWs(text, pos)
    ch := SubStr(text, pos, 1)
    if (ch = "{" || ch = "[") {
        isObj := (ch = "{")
        result := isObj ? {} : []
        closer := isObj ? "}" : "]"
        pos += 1
        Json_SkipWs(text, pos)
        if (SubStr(text, pos, 1) = closer) {
            pos += 1
            return result
        }
        Loop {
            if (isObj) {
                Json_SkipWs(text, pos)
                key := Json_String(text, pos)
                Json_SkipWs(text, pos)
                if (SubStr(text, pos, 1) != ":")
                    throw Exception("expected ':' at column " . pos)
                pos += 1
                result[key] := Json_Value(text, pos)
            } else {
                result.Push(Json_Value(text, pos))
            }
            Json_SkipWs(text, pos)
            ch := SubStr(text, pos, 1)
            pos += 1
            if (ch = closer)
                return result
            if (ch != ",")
                throw Exception("expected ',' or '" . closer . "' at column " . (pos - 1))
        }
    }
    if (ch = """")
        return Json_String(text, pos)
    if (RegExMatch(text, "\G-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", m, pos)) {
        pos += StrLen(m)
        return m + 0
    }
    for word, value in {"true": 1, "false": 0, "null": ""} {
        if (SubStr(text, pos, StrLen(word)) == word) {
            pos += StrLen(word)
            return value
        }
    }
    throw Exception("unexpected character at column " . pos)
}

Json_String(ByRef text, ByRef pos) {
    if (!RegExMatch(text, "\G""((?:[^""\\]++|\\.)*+)""", m, pos))
        throw Exception("expected string at column " . pos)
    pos += StrLen(m)
    s := m1
    if (!InStr(s, "\"))
        return s
    out := "", i := 1
    while (p := InStr(s, "\", true, i)) {
        out .= SubStr(s, i, p - i)
        c := SubStr(s, p + 1, 1)
        if (c == "u") {
            out .= Chr("0x" . SubStr(s, p + 2, 4))
            i := p + 6
        } else {
            out .= (c == "n") ? "`n" : (c == "r") ? "`r" : (c == "t") ? "`t" : (c == "b") ? Chr(8) : (c == "f") ? Chr(12) : c
            i := p + 2
        }
    }
    return out . SubStr(s, i)
}

Json_SkipWs(ByRef text, ByRef pos) {
    if (RegExMatch(text, "\G\s+", m, pos))
        pos += StrLen(m)
}
