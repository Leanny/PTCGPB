;===============================================================================
; BotBattleTutorial.ahk - "Battle Tutorial" mode
;===============================================================================
; Ported from BattleTutorialTest.ahk onto bot primitives:
;   BT_Tap   -> adbClick_wbb (same window->device conversion)
;   BT_Adb   -> adbWriteRaw / adbSwipe (device coords)
;   BT_Match -> from_window + GetNeedle (cached) + Gdip_ImageSearch_wbb
;   BT_Ocr   -> BTT_RapidOcr (RapidOCR-json.exe, device space)
;   BT_Log   -> LogInfo / LogWarn to Logs\BattleTutorial.txt
;   BTT_Status -> CreateStatusMessage (status bar) + BTT_Log
;
; Flow: battle screen -> Guide -> tutorial hub -> missions 00-06 at the blue
; frontier -> post-06 Solo/StepUp chain or Guide->StepUp repeat path ->
; BattleLobby -> first battle with auto on, retried until BattleWon ->
; BattleTutorialComplete confirms the account is done (flags.BT=1, written
; by the caller).
;===============================================================================

BTT_Log(msg) {
    global session
    LogInfo("[" . session.get("scriptName") . "] " . msg, "BattleTutorial.txt")
}

BTT_Fail(msg) {
    BTT_Log("FAIL: " . msg)
    CreateStatusMessage("Battle fail: " . msg,,,, false, true)
    return false
}

; Flow milestones on the status bar (bottom of the MuMu window), same
; channel the other modes use. Persist=true: the message stays up until
; the next one replaces it, since milestones can be minutes apart.
BTT_Status(msg) {
    BTT_Log(msg)
    CreateStatusMessage("Battle: " . msg,,,, false, true)
}

; ---- needle table: window-space coords, same as the test script ----
; fmt: [imageFile, x1, y1, x2, y2, tapX, tapY, variation]
BTT_Needles() {
    global g_bttNeedles
    if (IsObject(g_bttNeedles))
        return g_bttNeedles
    g_bttNeedles := {}
    g_bttNeedles["BattleActivated"] := ["BattleActivated.png", 176, 503, 194, 520, 185, 512, 25]
    g_bttNeedles["BattleGuide"]     := ["BattleGuide.png",     235, 339, 242, 350, 238, 344, 25]
    g_bttNeedles["BattleTutorial"]  := ["BattleTutorial.png",  115, 118, 152, 150, 134, 134, 25]
    g_bttNeedles["BattleTutorialEnd"] := ["BattleTutorialEnd.png", 176, 202, 213, 259, 194, 230, 25]
    g_bttNeedles["BattleInTutorial"] := ["BattleInTutorial.png", 127, 226, 140, 247, 134, 236, 25]
    g_bttNeedles["00Hand"]          := ["HandPointingUp.png",  110, 308, 172, 372, 143, 354, 85]
    g_bttNeedles["01TapAndHold"]    := ["HandPointingUp.png@180", 105, 441, 165, 495, 132, 461, 85]
    g_bttNeedles["01Hand"] := ["HandPointingTopLeft.png", 136, 320, 179, 356, 158, 338, 85]
    g_bttNeedles["01HandBench"] := ["HandPointingTopLeft.png", 136, 425, 180, 462, 158, 444, 85]
    g_bttNeedles["01Start"]         := ["HandPointingTopLeft.png@90", 194, 245, 250, 305, 228, 258, 85]
    g_bttNeedles["02Hand"] := ["HandPointingTopLeft.png", 129, 314, 177, 356, 138, 330, 85]
    g_bttNeedles["02Gnaw"] := ["HandPointingTopLeft.png", 149, 427, 197, 469, 154, 438, 85]
    g_bttNeedles["03Hand"] := ["HandPointingTopLeft.png", 132, 316, 180, 358, 156, 345, 85]
    g_bttNeedles["03Energy"]        := ["EnergyAssigned.png",  219, 474, 263, 522, 100, 376, 50]
    g_bttNeedles["04Hand"] := ["HandPointingTopLeft.png", 135, 320, 176, 351, 156, 336, 85]
    g_bttNeedles["04Tackle"] := ["HandPointingTopLeft.png", 145, 423, 193, 465, 245, 436, 85]
    g_bttNeedles["04HandBench"] := ["HandPointingTopLeft.png", 133, 422, 181, 464, 138, 450, 85]
    g_bttNeedles["04HandBench2"] := ["HandPointingTopLeft.png", 130, 434, 178, 476, 0, 0, 85]
    g_bttNeedles["05Energy"]        := ["EnergyAssigned.png",  219, 474, 263, 522, 146, 342, 50]
    g_bttNeedles["05Energy2"]       := ["EnergyAssigned.png",  219, 474, 263, 522, 246, 436, 50]
    g_bttNeedles["05Rollout"] := ["HandPointingTopLeft.png", 145, 423, 193, 465, 245, 436, 85]
    g_bttNeedles["05EnergyHand"] := ["HandPointingTopLeft.png", 132, 316, 180, 358, 157, 340, 85]
    g_bttNeedles["05TapAndHold"]    := ["HandPointingUp.png",  110, 308, 172, 372, 146, 345, 85]
    g_bttNeedles["06TapAndHold"]    := ["HandPointingUp.png@180", 105, 443, 165, 498, 132, 466, 85]
    g_bttNeedles["06Drag"] := ["HandPointingTopLeft.png", 127, 480, 187, 534, 153, 509, 85]
    g_bttNeedles["06Hand"] := ["HandPointingTopLeft.png", 123, 308, 183, 362, 154, 336, 85]
    g_bttNeedles["06CrimsonStorm"] := ["HandPointingTopLeft.png", 145, 417, 193, 459, 146, 430, 85]
    g_bttNeedles["06Solo"] := ["HandPointingTopLeft.png", 190, 386, 250, 440, 202, 402, 85]
    g_bttNeedles["06StepUp"] := ["HandPointingTopLeft.png", 190, 386, 250, 440, 202, 402, 85]
    g_bttNeedles["06StepUpBattle"] := ["HandPointingTopLeft.png", 124, 261, 184, 315, 146, 286, 85]
    g_bttNeedles["AutoOff"]         := ["AutoOff.png",         242, 493, 256, 507, 249, 500, 25]
    g_bttNeedles["StepUp"]          := ["StepUp.png",          200, 377, 212, 389, 206, 383, 25]
    g_bttNeedles["BattleLobby"]     := ["BattleLobby.png",     116,  89, 151, 120, 134, 104, 120]
    g_bttNeedles["AutoOn"]          := ["AutoOn.png",          242, 493, 256, 507, 249, 500, 25]
    g_bttNeedles["BattleToast"] := ["BattleToast.png", 127, 425, 140, 440, 134, 432, 25]
    g_bttNeedles["BattleWon"]       := ["BattleWon.png",       240,  42, 273,  69, 256,  56, 25]
    g_bttNeedles["BattleLost"]      := ["BattleLost.png",      240,  42, 273,  69, 256,  56, 25]
    g_bttNeedles["BattleTie"]       := ["BattleTie.png",       240,  42, 273,  69, 256,  56, 25]
    g_bttNeedles["BattleTutorialComplete"] := ["BattleTutorialComplete.png", 198, 271, 256, 325, 227, 298, 25]
    g_bttNeedles["BattleSingleTutorialComplete"] := ["BattleSingleTutorialComplete.png", 129, 252, 150, 271, 140, 262, 25]
    g_bttNeedles["CommunityTut"] := ["HandPointingTopLeft.png", 99, 446, 159, 500, 0, 0, 85]
    return g_bttNeedles
}

; Needles that match by shape instead of color: name -> min score %.
; Their PNGs are two-state masks (opaque dark = navy pixel required,
; opaque bright = non-navy pixel required). See MaskMatch.ahk.
BTT_MaskThreshold(name) {
    static m
    if (!IsObject(m))
        m := { "00Hand": 85, "01Hand": 85, "01HandBench": 85, "01TapAndHold": 85
            , "01Start": 85, "02Hand": 85, "02Gnaw": 85
            , "03Hand": 85, "04Hand": 85, "04HandBench": 85, "04HandBench2": 85
            , "04Tackle": 85, "05EnergyHand": 85, "05Rollout": 85, "06Drag": 85
            , "05TapAndHold": 85, "06TapAndHold": 85
            , "06CrimsonStorm": 85, "06Hand": 85, "06Solo": 85, "06StepUp": 85
            , "06StepUpBattle": 85, "CommunityTut": 85 }
    return m.HasKey(name) ? m[name] : 0
}

; window -> device conversion (same as adbClick)
BTT_DevX(wx) {
    return Round(wx * 540.0 / 283.0)
}

BTT_DevY(wy) {
    return Round((wy - 40) * 960.0 / 488.0)
}

BTT_DevTap(dx, dy) {
    adbWriteRaw("input tap " . dx . " " . dy)
    waitadb()
}

BTT_Tap(wx, wy) {
    adbClick_wbb(wx, wy)
}

BTT_Drag(wx1, wy1, wx2, wy2, durMs) {
    Sleep, 450   ; settle: let the previous spam tap's touch-up land first
    x1 := BTT_DevX(wx1), y1 := BTT_DevY(wy1)
    x2 := BTT_DevX(wx2), y2 := BTT_DevY(wy2)
    adbSwipe(x1 . " " . y1 . " " . x2 . " " . y2 . " " . durMs)
    BTT_Log("drag win(" . wx1 . "," . wy1 . ")->(" . wx2 . "," . wy2 . ") dev(" . x1 . "," . y1 . ")->(" . x2 . "," . y2 . ") " . durMs . "ms")
}

; Search needle inside its authored region on a fresh capture. Returns [x,y] or 0.
; expand=20: tutorial pointers bounce, a tight region misses them mid-animation
BTT_Match(name, expand := 20) {
    global session
    static pTokenLocal := 0
    if (!pTokenLocal)
        pTokenLocal := Gdip_Startup()
    ; heartbeat: BT runs outlive the monitor's 11-minute stuck threshold
    ; (7 missions + unbounded battle retries). Every wait loop funnels
    ; through here, so this keeps the watchdog fed the whole run.
    writeLastActivityEpoch(session.get("scriptName"), 4000)
    n := BTT_Needles()[name]
    pBitmap := from_window(getMuMuHwnd(session.get("winTitle")))
    if (!pBitmap) {
        BTT_Log(name . ": capture failed")
        return 0
    }
    file := n[1]
    if (p := InStr(file, "@"))
        file := SubStr(file, 1, p - 1)
    pNeedle := GetNeedle(A_ScriptDir . "\Needles\" . file)
    x1 := n[2] - expand, y1 := n[3] - expand, x2 := n[4] + expand, y2 := n[5] + expand
    Gdip_GetImageDimensions(pBitmap, bw, bh)
    if (x1 < 0)
        x1 := 0
    if (y1 < 0)
        y1 := 0
    if (x2 > bw)
        x2 := bw
    if (y2 > bh)
        y2 := bh
    if (thr := BTT_MaskThreshold(name)) {
        r := MM_MaskSearch(pBitmap, MM_LoadMask(A_ScriptDir . "\Needles\" . n[1]), x1, y1, x2, y2)
        ErrorCheckInScreen(pBitmap)
        Gdip_DisposeImage(pBitmap)
        if (r && r[3] * 100 >= thr) {
            BTT_Log(name . " mask " . Format("{:.1f}", r[3] * 100) . "% at " . r[1] . "," . r[2])
            return [r[1], r[2]]
        }
        return 0
    }
    found := Gdip_ImageSearch_wbb(pBitmap, pNeedle, pos, x1, y1, x2, y2, n[8])
    ErrorCheckInScreen(pBitmap)
    Gdip_DisposeImage(pBitmap)
    if (found && RegExMatch(pos, "(\d+)\s*,\s*(\d+)", m))
        return [m1 + 0, m2 + 0]
    return 0
}

; Tap (tx,ty) until needle matches, or timeout. Returns true when matched.
BTT_ClickUntilNeedle(name, tx, ty, timeoutSec) {
    deadline := A_TickCount + timeoutSec * 1000
    Loop {
        if (pos := BTT_Match(name)) {
            BTT_Log(name . " matched at " . pos[1] . "," . pos[2])
            return true
        }
        if (A_TickCount > deadline)
            return BTT_Fail(name . " not found within " . timeoutSec . "s")
        BTT_Tap(tx, ty)
        Sleep, 120
    }
}

; Do an action whose effect is proven by the pointer moving on: cur must be
; gone AND next must show. cur still (or again) on screen means the action
; did not land, so it is repeated. Neither on screen means a dialog sits in
; between: advance it with the usual spam tap.
BTT_ActUntilNext(cur, next, action, timeoutSec := 45, settleMs := 2000) {
    deadline := A_TickCount + timeoutSec * 1000
    lastAct := 0, acts := 0, curMisses := 0
    Loop {
        curUp := BTT_Match(cur)
        if (curUp) {
            curMisses := 0
            if (A_TickCount - lastAct >= settleMs) {
                if (acts)
                    BTT_Log(cur . " still up - repeating the action")
                action.Call()
                acts++
                lastAct := A_TickCount
            }
        } else {
            ; a single absent poll is just animation flicker - only accept
            ; "cur gone" after two misses in a row, or the next needle can
            ; fire while the game still waits for this action
            curMisses++
            if (curMisses >= 2 && (pos := BTT_Match(next))) {
                BTT_Log(next . " matched at " . pos[1] . "," . pos[2])
                return true
            }
            BTT_Tap(30, 360)
        }
        if (A_TickCount > deadline)
            return BTT_Fail(next . " not found within " . timeoutSec . "s after " . cur)
        Sleep, 120
    }
}

; Repeat the action while the prompt needle is up. Drag prompts animate the
; hand glyph along the drag path, so a next-step needle at the destination
; can fire mid-animation - instead this waits for the prompt to be absent
; for gonePolls consecutive polls, longer than the animation's excursion
; away from its source spot (the hand always returns to it).
BTT_ActUntilGone(cur, action, timeoutSec := 45, settleMs := 2000, gonePolls := 8) {
    deadline := A_TickCount + timeoutSec * 1000
    lastAct := 0, acts := 0, misses := 0, seen := false
    Loop {
        if (BTT_Match(cur)) {
            misses := 0, seen := true
            if (A_TickCount - lastAct >= settleMs) {
                if (acts)
                    BTT_Log(cur . " still up - repeating the action")
                action.Call()
                acts++
                lastAct := A_TickCount
            }
        } else {
            ; misses only count after the prompt was seen once - otherwise an
            ; animated hand in transit (or a delayed prompt) would read as
            ; "already done" and silently skip a step the game still wants
            if (seen) {
                misses++
                if (misses >= gonePolls) {
                    BTT_Log(cur . " gone for " . gonePolls . " polls")
                    return true
                }
            }
            BTT_Tap(30, 360)
        }
        if (A_TickCount > deadline)
            return BTT_Fail(cur . (seen ? " still present" : " never appeared") . " after " . timeoutSec . "s")
        Sleep, 120
    }
}

; Tap (tx,ty) until the needle stops matching twice in a row.
BTT_ClickUntilGone(name, tx, ty, timeoutSec, appearGraceMs := 2000) {
    deadline := A_TickCount + timeoutSec * 1000
    start := A_TickCount
    misses := 0, seen := false
    Loop {
        if (BTT_Match(name)) {
            misses := 0
            seen := true
        } else if (seen) {
            misses++
            if (misses >= 2) {
                BTT_Log(name . " gone")
                return true
            }
        } else if (A_TickCount - start > appearGraceMs) {
            BTT_Log(name . " never appeared - already gone")
            return true
        }
        if (A_TickCount > deadline)
            return BTT_Fail(name . " still present after " . timeoutSec . "s")
        BTT_Tap(tx, ty)
        Sleep, 120
    }
}

; True only if the needle matches continuously for the whole window -
; result banners persist, a transient frame that false-matches does not.
BTT_StableMatch(name, ms) {
    deadline := A_TickCount + ms
    while (A_TickCount < deadline) {
        if (!BTT_Match(name))
            return false
        Sleep, 200
    }
    return true
}

BTT_WaitNeedle(name, timeoutSec) {
    deadline := A_TickCount + timeoutSec * 1000
    Loop {
        if (pos := BTT_Match(name)) {
            BTT_Log(name . " matched at " . pos[1] . "," . pos[2])
            return pos
        }
        if (A_TickCount > deadline)
            return BTT_Fail(name . " not found within " . timeoutSec . "s")
        Sleep, 100
    }
}

; tap (tx,ty), then poll the needle every 100ms, re-tapping every reclickMs.
BTT_TapForNeedle(name, tx, ty, timeoutSec, reclickMs := 2000) {
    deadline := A_TickCount + timeoutSec * 1000
    nextClick := 0
    Loop {
        if (pos := BTT_Match(name)) {
            BTT_Log(name . " matched at " . pos[1] . "," . pos[2])
            return pos
        }
        if (A_TickCount > deadline)
            return BTT_Fail(name . " not found within " . timeoutSec . "s")
        if (A_TickCount >= nextClick) {
            BTT_Tap(tx, ty)
            nextClick := A_TickCount + reclickMs
        }
        Sleep, 100
    }
}

; ---- device-space screenshot + OCR ----
BTT_DevShot() {
    global session
    f := A_Temp . "\btt_shot_" . session.get("scriptName") . ".png"
    cmd := """" . session.get("adbPath") . """ -s " . AdbAddress() . " exec-out screencap -p > """ . f . """"
    RunWait, %ComSpec% /c "%cmd%", , Hide
    if (!FileExist(f))
        BTT_Log("screencap failed")
    return f
}

; ARGB -> {r,g,b}; avg of a 5x5 patch around (x,y) on the shot file
BTT_PixelAvg(shotFile, x, y) {
    static pTokenLocal := 0
    if (!pTokenLocal)
        pTokenLocal := Gdip_Startup()
    pBmp := Gdip_CreateBitmapFromFile(shotFile)
    if (!pBmp)
        return ""
    r := 0, g := 0, b := 0, n := 0
    Loop, 5 {
        yy := y - 2 + A_Index - 1
        Loop, 5 {
            xx := x - 2 + A_Index - 1
            ARGB := Gdip_GetPixel(pBmp, xx, yy)
            r += (ARGB >> 16) & 0xFF
            g += (ARGB >> 8) & 0xFF
            b += ARGB & 0xFF
            n++
        }
    }
    Gdip_DisposeImage(pBmp)
    return {r: r//n, g: g//n, b: b//n}
}

BTT_IsBlue(c) {
    ; active badge = saturated blue; locked = light gray
    return (c.b - c.r > 50 && c.b > 140)
}

; Scan visible mission badges: OCR digits + color classify.
; Device space: badge column ~x 45-115, rows y ~300-900.
BTT_ScanMissions() {
    shot := BTT_DevShot()
    if (!FileExist(shot))
        return BTT_Fail("screencap failed")
    words := BTT_RapidOcr(shot, "", 30, 290, 140, 610)
    if (!IsObject(words) || words.MaxIndex() = "")
        return BTT_Fail("OCR returned nothing on badge column")

    missions := []
    for _, w in words {
        t := Trim(w.text)
        if RegExMatch(t, "^\d{1,2}$") {
            ; badge pill is left of the digits: sample inside the colored arc
            c := BTT_PixelAvg(shot, w.x - 14, w.y + w.h // 2)
            if (!c)
                c := BTT_PixelAvg(shot, w.x + w.w + 8, w.y + w.h // 2)
            missions.Push({num: t + 0, y: w.y, cy: w.y + w.h // 2, cx: w.x + w.w // 2, blue: c ? BTT_IsBlue(c) : "?", rgb: c})
        }
    }
    if (missions.MaxIndex() = "")
        return BTT_Fail("no mission numbers found in column")

    ; sort by y
    Loop, % missions.MaxIndex() - 1 {
        i := A_Index
        Loop, % missions.MaxIndex() - i {
            j := A_Index
            if (missions[j].y > missions[j+1].y) {
                tmp := missions[j], missions[j] := missions[j+1], missions[j+1] := tmp
            }
        }
    }

    ; one-line report: B = blue/active, - = gray/locked
    s := "", lastBlue := ""
    for _, m in missions {
        s .= Format("{:02}", m.num) . (m.blue = 1 ? "B" : (m.blue = 0 ? "-" : "?")) . " "
        if (m.blue = 1)
            lastBlue := m.num
    }
    BTT_Log("scan: " . s . "| last blue " . (lastBlue = "" ? "none" : Format("{:02}", lastBlue)))
    return missions
}

; OCR the badge column: returns count of mission-number boxes still visible.
; Zero = we left the hub (inside a mission or a dialog covers the column).
BTT_HubNumbersVisible() {
    shot := BTT_DevShot()
    if (!FileExist(shot))
        return -1
    words := BTT_RapidOcr(shot, "", 30, 290, 140, 610)
    n := 0
    if (IsObject(words))
        for _, w in words
            if RegExMatch(Trim(w.text), "^\d{1,2}$")
                n++
    return n
}

; Swipe over the mission rows to reveal missions outside the visible window.
BTT_ScrollMissions(dir) {
    if (dir = "down")
        adbSwipe("8 700 8 350 400")
    else
        adbSwipe("8 350 8 700 400")
    BTT_Log("scroll missions " . dir)
    Sleep, 800
}

; Scan the badge column with retries: post-mission reward banners (BSTC),
; BTEnd and overlay tutorials can cover it. Dismisses them while retrying.
BTT_ScanHubRobust(timeoutSec := 15) {
    deadline := A_TickCount + timeoutSec * 1000
    missions := ""
    while (!IsObject(missions) && A_TickCount < deadline) {
        if (BTT_Match("BattleSingleTutorialComplete")) {
            BTT_Tap(140, 358)            ; reward banner OK
            Sleep, 800
        } else if (BTT_Match("BattleTutorialEnd")) {
            BTT_Tap(142, 432)            ; dev(271,771)
            Sleep, 600
        } else {
            missions := BTT_ScanMissions()
            if (!IsObject(missions)) {
                BTT_Tap(268, 370)        ; dev(511,649) - overlay dismiss
                Sleep, 700
            }
        }
    }
    return missions
}

; Scroll the hub mission list until every number in want[] shows up in the
; scan, or the list stops moving (top/bottom reached).
BTT_RevealMissions(missions, want, maxScrolls := 6) {
    prevKey := ""
    Loop, % maxScrolls + 1 {
        if (!IsObject(missions))
            return false
        minSeen := "", maxSeen := "", seen := {}
        for _, m in missions {
            seen[m.num] := 1
            if (minSeen = "" || m.num < minSeen)
                minSeen := m.num
            if (maxSeen = "" || m.num > maxSeen)
                maxSeen := m.num
        }
        allVisible := true, wantMax := ""
        for _, n in want {
            if (!seen.HasKey(n))
                allVisible := false
            if (wantMax = "" || n > wantMax)
                wantMax := n
        }
        if (allVisible)
            return missions
        key := minSeen . "-" . maxSeen
        ; 07 always follows 06 after a wider gap: only a repeated window with
        ; 07 already seen proves the list cannot reveal more - otherwise the
        ; gap may just have scrolled through without new numbers
        if ((key = prevKey && maxSeen >= 7) || A_Index > maxScrolls) {
            BTT_Log("list cannot reveal more (window " . key . ")")
            return missions
        }
        prevKey := key
        BTT_ScrollMissions(wantMax > maxSeen ? "down" : "up")
        missions := BTT_ScanMissions()
    }
    return missions
}

; Tap the mission number until BattleInTutorial proves we're inside (or the
; badge column is covered by something we dismiss). If the target isn't in
; the scan, scroll the list and rescan (BTT_RevealMissions).
BTT_EnterMission(ByRef missions, num) {
    missions := BTT_RevealMissions(missions, [num])
    if (!IsObject(missions))
        return false
    rowX := "", rowY := "", rowBlue := ""
    for _, m in missions
        if (m.num = num)
            rowX := m.cx, rowY := m.cy, rowBlue := m.blue
    if (rowY = "")
        return BTT_Fail("mission " . Format("{:02}", num) . " not found")
    if (rowBlue = 0) {
        ; the badge may still be unlocking after the previous mission -
        ; give it one rescan before failing instead of tapping a gray row
        Sleep, 2000
        missions := BTT_ScanMissions()
        if (IsObject(missions))
            for _, m in missions
                if (m.num = num)
                    rowX := m.cx, rowY := m.cy, rowBlue := m.blue
        if (rowBlue = 0)
            return BTT_Fail("mission " . Format("{:02}", num) . " still locked (gray)")
    }
    deadline := A_TickCount + 45000
    Loop {
        if (BTT_Match("BattleInTutorial")) {
            BTT_Log("BattleInTutorial matched - inside mission " . Format("{:02}", num))
            return true
        }
        if (BTT_Match("BattleTutorialEnd")) {
            BTT_Log("BTEnd during entry - dismissing")
            BTT_Tap(142, 432)
            Sleep, 600
            continue
        }
        if (BTT_Match("BattleSingleTutorialComplete")) {
            BTT_Log("reward banner during entry - dismissing OK")
            BTT_Tap(140, 358)
            Sleep, 600
            continue
        }
        if (BTT_HubNumbersVisible() = 0) {
            ; numbers gone could mean entering the mission - or a big
            ; tutorial covering the column. Confirm inside a short window.
            inner := A_TickCount + 8000
            covered := false
            while (A_TickCount < inner && A_TickCount < deadline) {
                if (BTT_Match("BattleInTutorial")) {
                    BTT_Log("BattleInTutorial matched - inside mission " . Format("{:02}", num))
                    return true
                }
                if (BTT_Match("BattleTutorialEnd")) {
                    BTT_Log("BTEnd covered the list - dismissing")
                    BTT_Tap(142, 432)
                    Sleep, 600
                    covered := true
                    break
                }
                if (BTT_Match("BattleSingleTutorialComplete")) {
                    BTT_Log("reward banner covered the list - dismissing OK")
                    BTT_Tap(140, 358)
                    Sleep, 600
                    covered := true
                    break
                }
                if (BTT_HubNumbersVisible() > 0) {
                    covered := true
                    break
                }
                Sleep, 300
            }
            if (!covered) {
                BTT_Log("badge numbers gone - inside mission " . Format("{:02}", num))
                return true
            }
            continue
        }
        if (A_TickCount > deadline)
            return BTT_Fail("still in hub after 45s")
        BTT_DevTap(rowX, rowY)
        BTT_Log("tap mission number dev(" . rowX . "," . rowY . ")")
        Sleep, 1500
    }
}

; Long-press at (devX,devY) until the needle stays unmatched for goneMs
; straight (the pointer flickers during the press, bursts of misses lie).
BTT_HoldUntilGone(name, devX, devY, timeoutSec, holdMs := 300, goneMs := 700) {
    deadline := A_TickCount + timeoutSec * 1000
    lastMatch := A_TickCount
    Loop {
        if (BTT_Match(name))
            lastMatch := A_TickCount
        else if (A_TickCount - lastMatch >= goneMs) {
            BTT_Log(name . " gone")
            return true
        }
        if (A_TickCount > deadline)
            return BTT_Fail(name . " still present after " . timeoutSec . "s")
        adbSwipe(devX . " " . devY . " " . devX . " " . devY . " " . holdMs)
        Sleep, 200
    }
}

; hub detection: header needle, plus visible mission numbers via OCR as
; a second proof. OCR is slow (~1.5s) so callers should not run it every
; loop iteration.
BTT_SeesHub() {
    if (BTT_Match("BattleTutorial"))
        return true
    n := BTT_HubNumbersVisible()
    if (n > 0) {
        BTT_Log("hub numbers visible (" . n . ") - in hub")
        return true
    }
    return false
}

; Shared mission ending: tap until the completion banner shows (dismiss its
; OK) or we're back in the hub (already-completed missions skip the banner).
BTT_FinishMission(tag) {
    deadline := A_TickCount + 120000
    nextOcr := 0
    Loop {
        if (BTT_Match("BattleSingleTutorialComplete")) {
            BTT_Log("BattleSingleTutorialComplete matched")
            BTT_Tap(140, 358)
            BTT_Log("dismissed completion OK")
            Sleep, 1500
            return "first"
        }
        if (A_TickCount >= nextOcr) {
            nextOcr := A_TickCount + 3000
            n := BTT_HubNumbersVisible()
            if (n > 0) {
                ; grace: a first-time banner can land just after the hub
                ; does - confirm "repeat" only if BSTC stays absent
                Sleep, 2000
                if (BTT_Match("BattleSingleTutorialComplete"))
                    continue
                BTT_Log("hub numbers visible (" . n . ") - back in hub")
                return "repeat"
            }
        }
        if (A_TickCount > deadline)
            return BTT_Fail("mission " . tag . " never finished")
        BTT_Tap(30, 360)
        Sleep, 120
        if (BTT_Match("BattleTutorial")) {
            ; same grace before calling it a repeat
            Sleep, 2000
            if (BTT_Match("BattleSingleTutorialComplete"))
                continue
            BTT_Log("back in hub - mission " . tag . " ended without banner")
            return "repeat"
        }
        if (A_TickCount > deadline)
            return BTT_Fail("mission " . tag . " never finished")
        BTT_Tap(30, 360)
        Sleep, 120
    }
}

BTT_RunMission00(missions) {
    if (!BTT_EnterMission(missions, 0))
        return BTT_Fail("could not enter mission 00")
    if (!BTT_ClickUntilNeedle("00Hand", 30, 360, 45))
        return BTT_Fail("00Hand never appeared")
    ; 00Hand center win(143,354) -> dev(273,618)
    if (!BTT_HoldUntilGone("00Hand", 273, 618, 45))
        return false
    return BTT_FinishMission("00")
}

BTT_RunMission01(missions) {
    if (!BTT_EnterMission(missions, 1))
        return BTT_Fail("could not enter mission 01")
    if (!BTT_ClickUntilNeedle("01TapAndHold", 30, 360, 45))
        return BTT_Fail("01TapAndHold never appeared")
    ; tap-and-hold at win(136,506) -> dev(260,917) until it clears
    if (!BTT_HoldUntilGone("01TapAndHold", 260, 917, 45))
        return false
    if (!BTT_ClickUntilNeedle("01Hand", 30, 360, 45))
        return BTT_Fail("01Hand never reappeared for first drag")
    if (!BTT_ActUntilGone("01Hand", Func("BTT_Drag").Bind(112, 503, 142, 330, 350)))
        return BTT_Fail("01Hand never cleared")
    if (!BTT_ActUntilGone("01HandBench", Func("BTT_Drag").Bind(140, 499, 137, 440, 350)))
        return BTT_Fail("01HandBench never cleared")
    if (!BTT_ClickUntilGone("01Start", 228, 258, 45))
        return BTT_Fail("01Start never dismissed")
    return BTT_FinishMission("01")
}

; Shared attack phase: at 1x tap the active pokemon, then press the attack
; button when its needle shows. Back to 3x on the way out.
BTT_AttackMove(needle, tx, ty, altNeedle := "", altTx := 0, altTy := 0, alreadySlow := false) {
    ; the card tap always runs at 1x - the active card is often still zooming
    ; and a 3x tap misses it. Every exit restores 3x (the attack fires at 1x,
    ; speed goes back up after it). Callers that already left the game at 1x
    ; (e.g. an unrestored energy attach) pass alreadySlow to skip the menu
    altHits := 0, slowed := true, altTapped := false
    if (!alreadySlow)
        SetGameSpeed(1)
    BTT_Tap(138, 330)          ; active pokemon -> dev(263,570) - opens the attack list
    lastCardTap := A_TickCount
    Sleep, 800
    deadline := A_TickCount + 45000
    nextOcr := A_TickCount + 1500
    Loop {
        ; already at 1x from entry - the !slowed checks only matter if a
        ; future caller skips the entry slowdown
        if (pos := BTT_Match(needle)) {
            if (!slowed) {
                SetGameSpeed(1)
                slowed := true
            }
            BTT_Log(needle . " matched at " . pos[1] . "," . pos[2])
            BTT_Tap(tx, ty)
            SetGameSpeed(3)
            Sleep, 800
            return true
        }
        ; alternate parked spot for an intermediate prompt (e.g. hand on the
        ; zoomed card that opens the attack list). Its region sits on the
        ; drag animation path, so require 2 consecutive hits - a passing hand
        ; must not fake it. The tap dismisses the intermediate step only:
        ; keep polling for the real attack prompt afterwards
        if (altNeedle != "" && pos := BTT_Match(altNeedle)) {
            altHits++
            if (altHits >= 2) {
                if (!slowed) {
                    SetGameSpeed(1)
                    slowed := true
                }
                BTT_Log(altNeedle . " held 2 polls at " . pos[1] . "," . pos[2] . " - intermediate prompt")
                BTT_Tap(altTx, altTy)
                altHits := 0, altTapped := true
                Sleep, 800
            }
        } else
            altHits := 0
        if (BTT_Match("BattleSingleTutorialComplete")) {
            BTT_Log("BSTC before " . needle . " - attack already fired")
            if (slowed)
                SetGameSpeed(3)
            return true
        }
        if (A_TickCount >= nextOcr) {
            nextOcr := A_TickCount + 3000
            if (BTT_SeesHub()) {
                BTT_Log("back in hub already - attack auto-fired")
                if (slowed)
                    SetGameSpeed(3)
                return true
            }
        }
        if (A_TickCount > deadline) {
            if (slowed)
                SetGameSpeed(3)
            return BTT_Fail(needle . " never appeared")
        }
        ; re-tap the card until the attack prompt exists - a first tap lost on
        ; a still-zooming card would otherwise poll to the deadline. Stops
        ; once an intermediate prompt was tapped (the next prompt owns the
        ; screen)
        if (!altTapped && A_TickCount - lastCardTap >= 2000) {
            BTT_Tap(138, 330)
            lastCardTap := A_TickCount
        }
        BTT_Tap(30, 360)
        Sleep, 120
    }
}

BTT_AttackGnaw(alreadySlow := false) {
    return BTT_AttackMove("02Gnaw", 154, 438, "", 0, 0, alreadySlow)
}

; Shared energy drag (missions 03+): at 1x drag win(244,496)->(136,334)
; dev(466,897)->(260,578), confirmed by 03Energy. Retries the drag.
BTT_EnergyDrag(restore3x := true) {
    SetGameSpeed(1)
    ok := false
    Loop, 3 {
        BTT_Drag(244, 496, 136, 334, 350)
        if (BTT_WaitNeedle("03Energy", 8)) {
            ok := true
            break
        }
        BTT_Log("energy drag not confirmed - retrying")
    }
    if (!ok)
        return BTT_Fail("03Energy never confirmed the drag")
    ; callers chaining straight into an attack pass restore3x=false - no
    ; point paying the 3x menu round-trip just to drop to 1x right after
    if (restore3x)
        SetGameSpeed(3)
    return true
}

; Energy attach: spam until the shared pointer, drop to 1x, drag the energy
; onto the active pokemon, retry until the confirm needle shows.
BTT_EnergyAttach(pointerNeedle, confirmNeedle, restore3x := true) {
    if (!BTT_ClickUntilNeedle(pointerNeedle, 30, 360, 45))
        return BTT_Fail(pointerNeedle . " never appeared for energy")
    SetGameSpeed(1)
    ok := false
    Loop, 3 {
        BTT_Drag(244, 496, 136, 334, 350)
        Sleep, 600
        deadline := A_TickCount + 8000
        misses := 0
        while (A_TickCount < deadline) {
            if (BTT_Match(confirmNeedle)) {
                ok := true
                break
            }
            if (BTT_Match(pointerNeedle))
                misses := 0
            else if (++misses >= 2) {
                ok := true
                break
            }
            Sleep, 100
        }
        if (ok)
            break
        BTT_Log(pointerNeedle . " still up - retrying")
    }
    ; callers chaining straight into an attack pass restore3x=false - no
    ; point paying the 3x menu round-trip just to drop to 1x right after
    if (restore3x)
        SetGameSpeed(3)
    if (!ok)
        return BTT_Fail(pointerNeedle . " pointer never moved on")
    return true
}

BTT_RunMission02(missions) {
    if (!BTT_EnterMission(missions, 2))
        return BTT_Fail("could not enter mission 02")
    if (!BTT_ClickUntilNeedle("02Hand", 30, 360, 45))
        return BTT_Fail("02Hand never appeared")
    if (!BTT_AttackGnaw())
        return false
    return BTT_FinishMission("02")
}

BTT_RunMission03(missions) {
    if (!BTT_EnterMission(missions, 3))
        return BTT_Fail("could not enter mission 03")
    if (!BTT_ClickUntilNeedle("03Hand", 30, 360, 45))
        return BTT_Fail("03Hand never appeared")
    if (!BTT_EnergyDrag())
        return false
    if (!BTT_ClickUntilNeedle("02Hand", 30, 360, 45))
        return BTT_Fail("02Hand never appeared for attack")
    if (!BTT_AttackGnaw())
        return false
    return BTT_FinishMission("03")
}

BTT_RunMission04(missions) {
    if (!BTT_EnterMission(missions, 4))
        return BTT_Fail("could not enter mission 04")
    if (!BTT_ClickUntilNeedle("04HandBench2", 30, 360, 45))
        return BTT_Fail("04HandBench2 never appeared")
    BTT_Drag(140, 499, 137, 440, 350)
    if (!BTT_ClickUntilNeedle("04Hand", 30, 360, 45))
        return BTT_Fail("04Hand never appeared")
    if (!BTT_AttackMove("04Tackle", 245, 436))
        return false
    ; bench tap at win(138,450) -> dev(263,807), at 1x so it registers
    if (!BTT_ClickUntilNeedle("04HandBench", 30, 360, 45))
        return BTT_Fail("04HandBench never appeared")
    SetGameSpeed(1)
    BTT_Tap(138, 450)
    Sleep, 800
    SetGameSpeed(3)
    if (!BTT_ClickUntilNeedle("03Hand", 30, 360, 45))
        return BTT_Fail("03Hand never appeared")
    if (!BTT_EnergyDrag(false))
        return false
    if (!BTT_ClickUntilNeedle("02Hand", 30, 360, 45))
        return BTT_Fail("02Hand never appeared for attack")
    if (!BTT_AttackGnaw(true))
        return false
    return BTT_FinishMission("04")
}

BTT_RunMission05(missions) {
    if (!BTT_EnterMission(missions, 5))
        return BTT_Fail("could not enter mission 05")
    if (!BTT_EnergyAttach("05EnergyHand", "05Energy"))
        return false
    if (!BTT_ClickUntilNeedle("05TapAndHold", 30, 360, 45))
        return BTT_Fail("05TapAndHold never appeared")
    if (!BTT_HoldUntilGone("05TapAndHold", 279, 600, 45))
        return false
    if (!BTT_ClickUntilNeedle("01Start", 30, 360, 45))
        return BTT_Fail("01Start never appeared")
    if (!BTT_ClickUntilGone("01Start", 228, 258, 45))
        return BTT_Fail("01Start never dismissed")
    if (!BTT_EnergyAttach("05EnergyHand", "05Energy2", false))
        return false
    if (!BTT_AttackMove("05Rollout", 245, 436, "", 0, 0, true))
        return false
    return BTT_FinishMission("05")
}

BTT_RunMission06(missions) {
    if (!BTT_EnterMission(missions, 6))
        return BTT_Fail("could not enter mission 06")
    if (!BTT_ClickUntilNeedle("06TapAndHold", 30, 360, 45))
        return BTT_Fail("06TapAndHold never appeared")
    if (!BTT_HoldUntilGone("06TapAndHold", 260, 915, 60, 500, 1500))
        return false
    ; drag hand -> active pokemon: win(153,509)->(136,334)
    if (!BTT_ClickUntilNeedle("06Drag", 30, 360, 45))
        return BTT_Fail("06Drag never appeared")
    if (!BTT_ActUntilGone("06Drag", Func("BTT_Drag").Bind(153, 509, 136, 334, 350)))
        return BTT_Fail("06Drag never cleared")
    if (!BTT_AttackMove("06CrimsonStorm", 146, 430, "06Hand", 154, 336))
        return false
    branch := BTT_FinishMission("06")
    if (!branch)
        return false
    return BTT_PostMission06(branch)
}

; After mission 06. BTT_FinishMission already resolved the branch: the BSTC
; completion banner only shows on first completion. First: spam the
; bottom-left corner dev(6,763) until the Solo prompt glyph shows. Solo and
; StepUp share the same glyph at the same spot and their buttons sit at the
; same point dev(387,708): keep tapping it until the 06StepUpBattle prompt
; appears -> dev(279,484) -> real battle screen. Repeat: walk back to
; Guide -> StepUp.
BTT_PostMission06(branch) {
    if (branch = "repeat") {
        BTT_Log("post-06 path: repeat")
        return BTT_RepeatToBattles()
    }
    deadline := A_TickCount + 45000
    while (!BTT_Match("06Solo")) {
        if (A_TickCount > deadline)
            return BTT_Fail("06Solo never appeared")
        BTT_Tap(3, 428)              ; dev(6,763)
        Sleep, 300
    }
    BTT_Log("post-06 path: first")
    ; Solo and StepUp are the same prompt glyph in the same spot, and the
    ; button to advance stays at dev(387,708): tap it until the
    ; StepUpBattle prompt appears
    if (!BTT_ClickUntilNeedle("06StepUpBattle", 203, 400, 90))
        return BTT_Fail("06StepUpBattle never appeared")
    BTT_Tap(146, 286)                    ; dev(279,484)
    Sleep, 800
    if (!BTT_ClickUntilNeedle("AutoOff", 3, 428, 90))
        return BTT_Fail("AutoOff never appeared - not at real battle")
    BTT_Status("Real battle screen reached")
    return BTT_BattleUntilWon()
}

; On Guide (BattleGuide): dev(387,708) opens StepUp -> dev(389,704) battles.
BTT_RepeatFromGuide() {
    BTT_Tap(203, 400)                    ; dev(387,708) - opens StepUp
    Sleep, 800
    if (!BTT_WaitNeedle("StepUp", 45))
        return BTT_Fail("StepUp never appeared")
    BTT_Tap(204, 398)                    ; dev(389,704) - enter battles
    Sleep, 800
    BTT_Log("entered battles via StepUp")
    return BTT_RunFirstBattle()
}

; Tutorial already finished (07 unlocked, 08 locked): from the mission hub
; walk back with dev(261,840) until Guide shows, then Guide -> StepUp.
BTT_RepeatToBattles() {
    if (!BTT_ClickUntilNeedle("BattleGuide", 137, 467, 45))
        return BTT_Fail("BattleGuide never appeared")
    return BTT_RepeatFromGuide()
}

; Scroll the lobby back to the top (drag down on the far-left edge) and
; report whether the completion badge is there. No badge yet means the
; scroll has not landed: it is repeated until timeoutSec runs out.
BTT_LobbyComplete(timeoutSec := 6) {
    deadline := A_TickCount + timeoutSec * 1000
    Loop {
        if (BTT_Match("BattleTutorialComplete")) {
            BTT_Status("Account completed")
            return true
        }
        if (A_TickCount > deadline)
            return false
        adbSwipe("8 400 8 800 400")
        Sleep, 700
    }
}

; Battle list (BattleLobby): if the completion badge is already there the
; account is done - otherwise tap the first battle at dev(258,476).
BTT_RunFirstBattle() {
    if (!BTT_WaitNeedle("BattleLobby", 45))
        return BTT_Fail("BattleLobby never appeared")
    BTT_Status("Battle lobby reached")
    if (BTT_LobbyComplete())
        return true                     ; already done - no battle needed
    BTT_Tap(135, 282)                    ; dev(258,476) - first battle
    Sleep, 800
    return BTT_BattleUntilWon()
}

; Battle flow: flip the auto toggle on (verified by AutoOn, retried), start
; the battle with dev(260,822), then spam until BattleWon, BattleLost or
; BattleTie shows. A loss shows BattleToast (dismiss dev 271,775) then
; lands back on the auto-toggle screen - retries until it wins. On victory
; tap dev(263,913) until back at the lobby.
BTT_BattleUntilWon() {
    attempt := 0
    Loop {
        attempt++
        BTT_Status("Battle attempt " . attempt)
        deadline := A_TickCount + 45000
        ready := false
        while (!ready) {
            if (BTT_Match("AutoOn")) {
                BTT_Log("AutoOn already on")
                ready := true
            } else if (BTT_Match("AutoOff")) {
                BTT_Log("AutoOff matched - toggling auto on")
                BTT_Tap(254, 500)        ; dev(485,905) - toggle auto on
                Sleep, 700
            } else if (A_TickCount > deadline) {
                return BTT_Fail("pre-battle auto toggle never showed")
            } else {
                ; retries come straight from the defeat toast - the game
                ; auto-navigates to the auto page, so the advance spam is
                ; only needed on the first attempt (entry path)
                if (attempt = 1)
                    BTT_Tap(30, 360)
                Sleep, 300
            }
        }
        BTT_Tap(136, 458)                ; dev(260,822) - start battle
        Sleep, 1000
        ; auto battle: taps until a result banner shows
        deadline := A_TickCount + 600000
        result := ""
        while (result = "") {
            ; persist check: result needles can false-match on
            ; transient battle frames - the real banner stays up
            if (BTT_Match("BattleWon") && BTT_StableMatch("BattleWon", 1500))
                result := "win"
            else if (BTT_Match("BattleLost") && BTT_StableMatch("BattleLost", 1500))
                result := "loss"
            else if (BTT_Match("BattleTie") && BTT_StableMatch("BattleTie", 1500))
                result := "loss"
            else if (A_TickCount > deadline)
                return BTT_Fail("battle never resolved")
            else {
                BTT_Tap(30, 360)         ; same spam point as the missions
                Sleep, 300
            }
        }
        if (result = "win") {
            BTT_Status("Battle won" . (attempt > 1 ? " on attempt " . attempt : ""))
            ; tap to the lobby - but a lingering BattleToast means
            ; the "win" was a false positive on a defeat screen
            winDeadline := A_TickCount + 45000
            confirmed := false
            while (!confirmed) {
                if (BTT_Match("BattleLobby")) {
                    confirmed := true
                } else if (BTT_Match("BattleToast")) {
                    BTT_Log("not a win - defeat toast showed")
                    result := "loss"
                    break
                } else if (A_TickCount > winDeadline) {
                    return BTT_Fail("won but BattleLobby never returned")
                } else {
                    BTT_Tap(138, 504)        ; dev(263,913)
                    Sleep, 300
                }
            }
            if (result = "win") {
                BTT_Log("back at battle lobby")
                ; the lobby comes back scrolled down - scroll to top and
                ; the completion badge confirms the account is done
                if (!BTT_LobbyComplete(45))
                    return BTT_Fail("won but BattleTutorialComplete never showed")
                return true
            }
        }
        ; lost: the defeat toast slides in a beat after the banner. Wait for
        ; it to actually appear (or for the auto-toggle if none comes) -
        ; ClickUntilGone's early misses would see "gone" mid-transition
        BTT_Status("Battle lost - retrying")
        toastDeadline := A_TickCount + 10000
        while (A_TickCount < toastDeadline) {
            if (BTT_Match("BattleToast") || BTT_Match("AutoOn") || BTT_Match("AutoOff"))
                break
            BTT_Tap(30, 360)
            Sleep, 300
        }
        if (BTT_Match("BattleToast")) {
            if (!BTT_ClickUntilGone("BattleToast", 134, 432, 45))
                return BTT_Fail("BattleToast never dismissed")
        }
    }
}

; Press the Guide button until the tutorial hub shows. The second tutorial
; chain can pop up at any point until the hub is confirmed, so the prompt
; glyph is re-checked every poll and the CommunityDeck dismiss flow runs
; whenever it appears.
BTT_TapForHub(timeoutSec := 45) {
    deadline := A_TickCount + timeoutSec * 1000
    nextClick := 0
    Loop {
        if (pos := BTT_Match("BattleTutorial")) {
            BTT_Log("BattleTutorial matched at " . pos[1] . "," . pos[2])
            return pos
        }
        if (A_TickCount > deadline)
            return BTT_Fail("BattleTutorial never appeared")
        if (!BTT_DismissCommunityTut())
            return false
        if (A_TickCount >= nextClick) {
            BTT_Tap(239, 346)
            nextClick := A_TickCount + 400
        }
        Sleep, 100
    }
}

; Moving to the battle tab can raise a second tutorial chain, confirmed by
; the TopLeft prompt glyph at win(111,458). dev(204,830) dismisses it into
; the CommunityDeck screen; dev(355,771) clears each deck tutorial popup
; until BattleActivated shows again, and dev(261,838) brings back Guide.
BTT_DismissCommunityTut() {
    if (!BTT_Match("CommunityTut"))
        return true
    BTT_Log("second tutorial prompt - dismissing")
    BTT_Tap(107, 462)                ; dev(204,830)
    ; on CommunityDeck once the prompt glyph is confirmed gone
    deadline := A_TickCount + 45000, gone := 0
    while (gone < 3) {
        if (A_TickCount > deadline)
            return BTT_Fail("second tutorial glyph never cleared")
        gone := BTT_Match("CommunityTut") ? 0 : gone + 1
        Sleep, 200
    }
    ; deck tutorial popups: dismiss until the battle tab shows again
    deadline := A_TickCount + 45000
    while (!BTT_Match("BattleActivated")) {
        if (A_TickCount > deadline)
            return BTT_Fail("BattleActivated never reappeared")
        BTT_Tap(186, 432)            ; dev(355,771)
        Sleep, 300
    }
    BTT_Tap(137, 466)                ; dev(261,838) -> Guide visible
    Sleep, 800
    return true
}

; ---- entry point: called after startPreProcess lands on the battle screen
; (BattleActivated confirmed). Returns true when the account is marked
; complete for this mode (BattleTutorialComplete seen).
BotBattleTutorial_Run() {
    global session
    BTT_Log("=== Battle Tutorial run start | account=" . session.get("accountFileName") . " ===")
    BTT_Status("Starting")

    ; press the Guide button until the tutorial hub shows. The second
    ; tutorial chain is re-checked every poll until the hub is confirmed.
    if (!BTT_TapForHub(45))
        return false
    BTT_Status("In tutorial hub")

    ; the hub itself may chain first-time tutorials: dismiss with
    ; dev(511,649). The chain ends on BattleTutorialEnd, dismissed with
    ; dev(271,771). Exit only when numbers are readable AND BTEnd is gone.
    deadline := A_TickCount + 45000
    nextOcr := A_TickCount + 800        ; first numbers check after ~1s
    Loop {
        if (A_TickCount > deadline)
            return BTT_Fail("hub tutorials never cleared")
        if (BTT_Match("BattleTutorialEnd")) {
            BTT_Log("BattleTutorialEnd - dismissing")
            BTT_Tap(142, 432)            ; dev(271,771)
            Sleep, 300
            continue
        }
        ; OCR is slow (~1.5s) - check numbers periodically, not per tap
        if (A_TickCount >= nextOcr) {
            if (BTT_HubNumbersVisible())
                break
            nextOcr := A_TickCount + 1500
        }
        BTT_Tap(268, 370)            ; dev(511,649)
        Sleep, 150
    }

    ; resume at the frontier: the last blue badge before the first gray
    ; (locked) one. If no gray is visible after the last blue, scroll down
    ; until one shows or the list ends - the gray number confirms it.
    startNum := 0
    frontier := BTT_ScanMissions()
    Loop, 8 {
        if (!IsObject(frontier))
            break
        lastBlue := "", firstGray := "", maxSeen := ""
        for _, m in frontier {
            if (m.blue = 1 && (lastBlue = "" || m.num > lastBlue))
                lastBlue := m.num
            else if (m.blue = 0 && lastBlue != "" && m.num > lastBlue && (firstGray = "" || m.num < firstGray))
                firstGray := m.num
            if (maxSeen = "" || m.num > maxSeen)
                maxSeen := m.num
        }
        ; the numbered list always continues past 06 to 07 (wider gap than
        ; the 00-06 spacing) - keep scrolling until it is seen so a locked
        ; badge behind the gap is not mistaken for the end of the list
        if (lastBlue = "" || firstGray != "" || maxSeen >= 7) {
            startNum := (lastBlue = "" ? 0 : lastBlue)
            break
        }
        BTT_ScrollMissions("down")
        frontier := BTT_ScanMissions()
    }
    if (firstGray = "" && lastBlue != "")
        startNum := lastBlue
    BTT_Log("start frontier: mission " . Format("{:02}", startNum) . (firstGray != "" ? " (next locked " . Format("{:02}", firstGray) . ")" : ""))

    ; a frontier past 06 (07 or later unlocked) means every tutorial mission
    ; is done - skip to the post-06 final branch, which only succeeds on the
    ; completion badge
    if (startNum > 6) {
        BTT_Status("Tutorial already done - heading to battles")
        return BTT_RepeatToBattles()
    }

    ; run the listed missions back to back; every mission ends in the hub
    for _, num in [0, 1, 2, 3, 4, 5, 6] {
        if (num < startNum)
            continue
        missions := BTT_ScanHubRobust()
        if (!IsObject(missions))
            return BTT_Fail("no mission list found")
        BTT_Status("Running mission 0" . num)
        fn := "BTT_RunMission0" . num
        if (!%fn%(missions))
            return BTT_Fail("mission 0" . num . " failed - aborting sequence")
        BTT_Status("Mission 0" . num . " done")
        BTT_Log("mission 0" . num . " finished - rescanning hub")
        ; 06's post-flow lands outside the hub - nothing left to rescan
        if (num >= 6) {
            BTT_Log("sequence complete")
            return true
        }
        ; settle + dismiss any post-mission overlays before next entry
        BTT_ScanHubRobust()
        Sleep, 500
    }
    return BTT_Fail("mission sequence ended without reaching the battle")
}

; Sets flags.BT=1 on the loaded account's metadata JSON.
BotBattleTutorial_MarkDone() {
    global session
    accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), session.get("loadedAccount"))
    accountMeta["deviceAccount"] := GetCurrentDeviceAccountForMetadata()
    if (!accountMeta["flags"].HasKey("BT"))
        accountMeta["flags"]["BT"] := AccountMetadata_NewFlag(0)
    accountMeta["flags"]["BT"]["value"] := 1
    accountMeta["flags"]["BT"]["setAt"] := AccountMetadata_Now()
    accountMeta["flags"]["BT"]["validUntil"] := ""
    AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)
    BTT_Log("flags.BT=1 written for " . session.get("accountFileName"))
}

;-------------------------------------------------------------------------------
; BTT_RapidOcr - OCR via RapidOCR-json.exe (PP-OCR ONNX models), downloaded
; into rapidocr\ at release packaging time. Returns a word array
; ({text, x, y, w, h}) in device space.
;-------------------------------------------------------------------------------
BTT_RapidOcrLang(ocrTag) {
    ; The default ch_PP-OCRv3 recognizer already covers digits and the Latin
    ; alphabet; CJK locales get their dedicated rec model + keyset.
    if (ocrTag = "ja")
        return " --rec rec_japan_PP-OCRv3_infer.onnx --keys dict_japan.txt"
    if (ocrTag = "ko")
        return " --rec rec_korean_PP-OCRv3_infer.onnx --keys dict_korean.txt"
    if (ocrTag ~ "^zh")
        return " --rec rec_chinese_cht_PP-OCRv3_infer.onnx --keys dict_chinese_cht.txt"
    return ""
}

; Save a (x,y,w,h) slice of a PNG via GDI+. Used to OCR a small screen
; region instead of the full frame (much faster).
BTT_CropImage(srcFile, dstFile, x, y, w, h) {
    pBmp := Gdip_CreateBitmapFromFile(srcFile)
    if (!pBmp)
        return false
    pCrop := Gdip_CloneBitmapArea(pBmp, x, y, w, h)
    Gdip_DisposeImage(pBmp)
    if (!pCrop)
        return false
    ok := (Gdip_SaveBitmapToFile(pCrop, dstFile) = 0)
    Gdip_DisposeImage(pCrop)
    return ok
}

BTT_RapidOcr(shotFile, ocrTag := "", cX := 0, cY := 0, cW := 0, cH := 0) {
    global session
    static exe := ""
    static exeDir := ""
    if (exe = "") {
        exeDir := getScriptBaseFolder() . "\rapidocr"
        Loop, Files, %exeDir%\*RapidOCR*.exe
            exe := A_LoopFileFullPath
        if (exe = "")
            exeDir := getScriptBaseFolder() . "\rapidocr\RapidOCR-json_v0.2.0"
        Loop, Files, %exeDir%\*.exe
            if (InStr(A_LoopFileName, "RapidOCR")) {
                exe := A_LoopFileFullPath
                exeDir := A_LoopFileDir
                break
            }
        if (exe = "")
            exe := false
    }
    if (!exe)
        return ""
    ; Optional (cX,cY,cW,cH): OCR only that region of the frame. Returned word
    ; coordinates stay absolute (offset back), so callers are unchanged.
    ocrFile := shotFile
    if (cW > 0 && cH > 0) {
        cropFile := A_Temp . "\rapidocr_crop_" . session.get("scriptName") . ".png"
        if (BTT_CropImage(shotFile, cropFile, cX, cY, cW, cH))
            ocrFile := cropFile
        else
            cX := 0, cY := 0 ; crop failed: fall back to the full frame
    }
    cmd := """" . exe . """ --image_path """ . ocrFile . """ --ensureLogger 0 --doAngle 0 --mostAngle 0" . BTT_RapidOcrLang(ocrTag)
    outFile := A_Temp . "\rapidocr_" . session.get("scriptName") . ".json"
    RunWait, %ComSpec% /c cd /d "%exeDir%" && %cmd% > "%outFile%", , Hide
    if (!FileExist(outFile))
        return ""
    FileRead, json, *P65001 %outFile% ; RapidOCR emits UTF-8 without BOM
    FileDelete, %outFile%
    words := []
    pos := 1
    re := """box"":\[\[(\d+),(\d+)\],\[(\d+),(\d+)\],\[(\d+),(\d+)\],\[(\d+),(\d+)\]\],""score"":[\d\.eE+-]+,""text"":""([^""]*)"""
    While (p := RegExMatch(json, re, m, pos)) {
        if (m9 = "") {
            pos := p + StrLen(m)
            continue
        }
        xs := [m1 + 0, m3 + 0, m5 + 0, m7 + 0], ys := [m2 + 0, m4 + 0, m6 + 0, m8 + 0]
        minX := xs[1], maxX := xs[1], minY := ys[1], maxY := ys[1]
        for _, v in xs {
            if (v < minX)
                minX := v
            if (v > maxX)
                maxX := v
        }
        for _, v in ys {
            if (v < minY)
                minY := v
            if (v > maxY)
                maxY := v
        }
        words.Push({text: m9, x: minX + cX, y: minY + cY, w: maxX - minX, h: maxY - minY})
        pos := p + StrLen(m)
    }
    return words
}
