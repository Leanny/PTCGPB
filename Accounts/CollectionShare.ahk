;===============================================================================
; CollectionShare.ahk - Daily auto-share of missing Main collection cards
;
; Main.ahk (coordinator): once per server-reset day, re-imports the Main
;   collection and computes the first missing shareable card, writing a
;   task file under Accounts\Cards\share\.
;
; Numbered instances (donors): at end of run, before friend removal, the first
;   injected account owning the target card claims the task atomically,
;   favourites the Main and performs the in-game share.
;
; Task files carry their state in the name (<day> is the server-reset day):
;   <day>_<Main>_waiting-for-donor.json   target set, no donor took it yet
;   <day>_<Main>_share-in-progress.json   a donor is sharing right now
;   <day>_<Main>_shared.json              card shared
;   <day>_<Main>_already-received.json    Main had already received a share
;   <day>_<Main>_no-card-available.json   no account owns a missing card
;   <day>_donor-attempt_<account>.txt     that account used its daily attempt
;===============================================================================

ShareTaskDir() {
    return getScriptBaseFolder() . "\Accounts\Cards\share"
}

; Server-reset day as YYYY-MM-DD, the prefix of every share file
ShareTaskDay() {
    cycleKey := getShowcaseLikesCycleKey()
    return SubStr(cycleKey, 1, 4) . "-" . SubStr(cycleKey, 5, 2) . "-" . SubStr(cycleKey, 7, 2)
}

ShareTaskPath(day, mainInstance, state) {
    return ShareTaskDir() . "\" . day . "_" . mainInstance . "_" . state . ".json"
}

; Renames a task file to another state; returns the new path, "" on failure.
; MoveFile is atomic and fails when the source is already gone, so only one
; instance wins a claim (FileMove reports success for a missing source file).
ShareTaskSetState(taskPath, state) {
    newPath := RegExReplace(taskPath, "_[a-z-]+\.json$", "_" . state . ".json")
    return DllCall("MoveFileW", "WStr", taskPath, "WStr", newPath) ? newPath : ""
}

ShareTaskPendingFiles(day) {
    files := []
    Loop, Files, % ShareTaskDir() . "\" . day . "_*_waiting-for-donor.json", F
        files.Push(A_LoopFileFullPath)
    return files
}

ShareTaskRead(taskPath) {
    task := { cardId: "", friendCode: "", mainInstance: "", sortMode: "expansion", collection: "", expansion: "" }
    FileRead, text, % taskPath
    if (RegExMatch(text, """cardId""\s*:\s*""([^""]+)""", m))
        task.cardId := m1
    if (RegExMatch(text, """friendCode""\s*:\s*""([^""]+)""", m))
        task.friendCode := m1
    if (RegExMatch(text, """mainInstance""\s*:\s*""([^""]+)""", m))
        task.mainInstance := m1
    if (RegExMatch(text, """sortMode""\s*:\s*""([^""]+)""", m) && m1 = "rarity")
        task.sortMode := "rarity"
    if (RegExMatch(text, """collection""\s*:\s*""([^""]+)""", m))
        task.collection := m1
    if (RegExMatch(text, """expansion""\s*:\s*""([^""]+)""", m))
        task.expansion := m1
    return task
}

ShareTaskClaim(taskPath) {
    ; Stamp the claim time before the rename: ShareTaskReleaseStale reads it
    FileSetTime, , % taskPath
    return ShareTaskSetState(taskPath, "share-in-progress")
}

ShareTaskRelease(claimedPath) {
    return (ShareTaskSetState(claimedPath, "waiting-for-donor") != "")
}

; A claim that is neither finished nor released (instance restarted mid-share)
; would block the task for the whole day: hand it back after maxAgeSec.
ShareTaskReleaseStale(day, maxAgeSec := 600) {
    Loop, Files, % ShareTaskDir() . "\" . day . "_*_share-in-progress.json", F
    {
        age := A_Now
        EnvSub, age, %A_LoopFileTimeModified%, Seconds
        if (age > maxAgeSec && ShareTaskRelease(A_LoopFileFullPath))
            LogWarn("CollectionShare: released stale claim " . A_LoopFileName . " (" . age . "s old)")
    }
}

ShareCarddbJson(subArgs, outFile) {
    helperPath := AccountMetadata_HelperPath()
    if (!FileExist(helperPath))
        return ""
    root := getScriptBaseFolder()
    cmd := """" . helperPath . """ --root """ . root . """ " . subArgs . " --out """ . outFile . """"
    RunWait, % cmd, , Hide
    if (ErrorLevel || !FileExist(outFile))
        return ""
    FileRead, text, % outFile
    FileDelete, % outFile
    return text
}

ShareAccountOwnsCard(deviceAccount, cardId) {
    outFile := A_Temp . "\share_check_" . A_TickCount . ".json"
    result := ShareCarddbJson("check-owned --device-account """ . deviceAccount . """ --card """ . cardId . """", outFile)
    return (result != "" && RegExMatch(result, """owned""\s*:\s*true"))
}

ShareMarkCardShared(deviceAccount, cardId) {
    helperPath := AccountMetadata_HelperPath()
    if (!FileExist(helperPath))
        return false
    root := getScriptBaseFolder()
    RunWait, % """" . helperPath . """ --root """ . root . """ mark-shared --device-account """ . deviceAccount . """ --card """ . cardId . """", , Hide
    return !ErrorLevel
}

; Records the card as shared-but-unclaimed on the Main collection so the next
; share-target computation skips it until the Main actually registers it.
ShareMarkPendingShare(collection, cardId) {
    if (collection = "" || cardId = "")
        return false
    helperPath := AccountMetadata_HelperPath()
    if (!FileExist(helperPath))
        return false
    root := getScriptBaseFolder()
    RunWait, % """" . helperPath . """ --root """ . root . """ mark-pending-share --collection """ . collection . """ --card """ . cardId . """", , Hide
    return !ErrorLevel
}

;-------------------------------------------------------------------------------
; CollectionShare_EnsureSocial - Navigate back to the Social hub on screen
;-------------------------------------------------------------------------------
CollectionShare_EnsureSocial() {
    global session

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if (DismissFriendFlowBlockingPopup("Share: waiting for Social"))
            continue

        if (IsSocialTabActiveOnHub(0))
            return true

        ; Unwind nested friend screens first: the Social tab is not reachable
        ; from friend details or the search dialog.
        if (IsFriendProfileDetailsOpen()) {
            adbClick_wbb(143, 507) ; back from friend profile details
        } else if (IsFriendSearchDialogOpen()) {
            adbClick_wbb(80, 365) ; close search window (same as Main.ahk)
        } else {
            adbClick_wbb(143, 518) ; Social tab
        }

        ; Same recovery branches as the RemoveFriends Social wait
        if (IsSocialTabActiveOnHub(0))
            return true
        else if (FindOrLoseImage("Common_PopupXButtonInMain", 0, , , true)) {
            adbClick_wbb(137, 480)
            Delay(1)
        }
        else if (TryHandleTradeTutorial(failSafeTime))
            continue
        else if (TryDismissSocialFirstTutorial(failSafeTime))
            continue
        else if (FindOrLoseImage("Create_TutorialUseResourceForOpenPack", 0)) {
            Delay(3)
            adbClick_wbb(146, 441)
            Delay(3)
            adbClick_wbb(146, 441)
            Delay(3)
            adbClick_wbb(146, 441)
            Delay(3)
            FindImageAndClick("Create_TutorialPremiumPass", 168, 438, , 500, 5)
            Delay(1)
            adbClick_wbb(203, 436)
        }
        else if (!ShouldSkipGenericButtonInSocialWait()) {
            clickButton := FindOrLoseImage("Common_ColorChangeButton", 0, , 80)
            if (clickButton) {
                StringSplit, pos, clickButton, `,
                adbClick_wbb(pos1, pos2)
            }
        }
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        if (failSafeTime > 90) {
            LogWarn("CollectionShare: could not reach Social screen")
            return false
        }
        CreateStatusMessage("Share: waiting for Social`n(" . failSafeTime . "/90 seconds)")
        Delay(7)
    }
}

;-------------------------------------------------------------------------------
; CollectionShare_BackToSocial - Back out of nested share screens until the
;   Social hub is on screen. The Social tab is not visible from them.
;-------------------------------------------------------------------------------
CollectionShare_BackToSocial(maxBacks := 8) {
    Loop, % maxBacks + 1 {
        if (IsSocialTabActiveOnHub(0))
            return true
        if (A_Index > maxBacks)
            break
        CreateStatusMessage("Share: backing out to Social...")
        adbInputEvent("111") ; ESC = back
        Delay(6)
    }
    LogWarn("CollectionShare: could not back out to Social screen")
    return false
}

;-------------------------------------------------------------------------------
; CollectionShare_WaitScreenNeedle - Poll a coordinate-mode needle until timeout
;-------------------------------------------------------------------------------
CollectionShare_WaitScreenNeedle(imageName, x1, y1, x2, y2, timeoutSec) {
    start := A_TickCount
    Loop {
        elapsed := (A_TickCount - start) // 1000
        if (FindOrLoseImage(x1, y1, x2, y2, , imageName, 0, elapsed))
            return true
        if (elapsed >= timeoutSec)
            return false
        Sleep, 400
    }
}

;-------------------------------------------------------------------------------
; CollectionShare_ClassifyFriendResult - Identify the friend-search outcome
;-------------------------------------------------------------------------------
CollectionShare_ClassifyFriendResult() {
    global session

    session.set("failSafe", A_TickCount)
    Loop {
        Delay(1)
        if (FindOrLoseImage("GPTest_FriendedInSearcResult", 0, , , true)
            || FindOrLoseImage("Friend_AcceptedButtonInSearchResult", 0, , , true)
            || FindOrLoseImage("Friend_AcceptedButtonInFriendDetails", 0, , , true))
            return "friended"
        if (FindOrLoseImage("Friend_RequestButtonInSearchResult", 0, , , true)
            || FindOrLoseImage("Friend_ReqeustButtonInFriendDetails", 0, , , true)
            || FindOrLoseImage("Friend_ReqeustButtonInFriendDetails2", 0, , , true))
            return "request"
        if (FindOrLoseImage("Friend_WithdrawButton", 0, , , true)
            || FindOrLoseImage("GPTest_ReqeustCancelButtonInSearchResult", 0, , , true))
            return "pending"
        if (FindOrLoseImage("GPTest_AccountNotFound", 0, , , true))
            return "notfound"
        if (FindOrLoseImage("Friend_CannotFriendRequest", 0, , , true))
            return "cannot"
        if (interceptErrorCheck("ADD"))
            return "error"
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        if (failSafeTime > 45)
            return "timeout"
        CreateStatusMessage("Share: checking Main friend status`n(" . failSafeTime . "/45 seconds)")
    }
}

;-------------------------------------------------------------------------------
; CollectionShare_ResearchFriend - Re-submit the friend-code search
;-------------------------------------------------------------------------------
CollectionShare_ResearchFriend(friendCode) {
    FindImageAndClick("Friend_SearchFriendWindowCancelButtonCorner", 143, 518, , 1000)
    FindImageAndClick("Friend_FriendIDInputReady", 138, 265, , 1000)
    if (!SubmitFriendIDSearch(friendCode, 1, 1))
        return "error"
    return CollectionShare_ClassifyFriendResult()
}

;-------------------------------------------------------------------------------
; CollectionShare_WaitFriendAccepted - Wait until Main accepts the request
;-------------------------------------------------------------------------------
CollectionShare_WaitFriendAccepted(friendCode, timeoutSec) {
    global session

    start := A_TickCount
    lastResearch := 0
    Loop {
        Delay(1)
        if (FindOrLoseImage("Friend_AcceptedButtonInSearchResult", 0, , , true)
            || FindOrLoseImage("GPTest_FriendedInSearcResult", 0, , , true)
            || FindOrLoseImage("Friend_AcceptedButtonInFriendDetails", 0, , , true))
            return true
        if (interceptErrorCheck("ADD"))
            return false
        elapsed := (A_TickCount - start) // 1000
        if (elapsed >= timeoutSec) {
            LogWarn("CollectionShare: Main did not accept friend request within " . timeoutSec . "s")
            return false
        }
        ; The search result does not refresh by itself: re-submit every ~15s
        if ((A_TickCount - lastResearch) >= 15000) {
            lastResearch := A_TickCount
            state := CollectionShare_ResearchFriend(friendCode)
            if (state = "friended")
                return true
            if (state = "notfound" || state = "cannot" || state = "error")
                return false
        }
        CreateStatusMessage("Share: waiting for Main to accept`n(" . elapsed . "/" . timeoutSec . " seconds)")
    }
}

;-------------------------------------------------------------------------------
; CollectionShare_FavouriteCurrentProfile - Star the currently open friend profile
;-------------------------------------------------------------------------------
CollectionShare_FavouriteCurrentProfile() {
    global session

    enterStart := A_TickCount
    Loop {
        if (!FindOrLoseImage("GPTest_FriendedInSearcResult", 0, , , true)
            && !FindOrLoseImage("Friend_AcceptedButtonInSearchResult", 0, , , true))
            break
        if ((A_TickCount - enterStart) // 1000 > 30)
            break
        adbClick_wbb(143, 258)
        Sleep, 500
        CreateStatusMessage("Share: entering Main profile...")
    }

    profStart := A_TickCount
    Loop {
        if (FindOrLoseImage("GPTest_NotFavouriteInDetails", 0, , , true)
            || FindOrLoseImage("GPTest_FavouritedInDetails", 0, , , true))
            break
        if ((A_TickCount - profStart) // 1000 > 30)
            break
        Sleep, 500
        CreateStatusMessage("Share: waiting for Main profile...")
    }

    if (FindOrLoseImage("GPTest_NotFavouriteInDetails", 0, , , true)) {
        adbClick(252, 81)
        Delay(1)
        Sleep, 500
    }

    if (!FindOrLoseImage("GPTest_FavouritedInDetails", 0, , , true)) {
        LogWarn("CollectionShare: could not favourite Main profile")
        return false
    }
    return true
}

;-------------------------------------------------------------------------------
; CollectionShare_FavouriteMain - Friend request + favourite for the Main code
;-------------------------------------------------------------------------------
CollectionShare_FavouriteMain(friendCode) {
    global session

    if (friendCode = "" || StrLen(friendCode) != 16)
        return false
    if (!CollectionShare_EnsureSocial())
        return false

    FindImageAndClick("Friend_AddButtonInFriendList", 38, 460, , 500)
    FindImageAndClick("Friend_SearchFriendButton", 240, 120)
    Delay(1)
    FindImageAndClick("Friend_SearchFriendWindowCancelButtonCorner", 75, 440)
    FindImageAndClick("Friend_FriendIDInputReady", 138, 265)

    if (!SubmitFriendIDSearch(friendCode, 1, 1))
        return false

    state := CollectionShare_ClassifyFriendResult()
    if (state = "request" || state = "pending") {
        if (state = "request") {
            if (FindOrLoseImage("Friend_ReqeustButtonInFriendDetails", 0, , , true)
                || FindOrLoseImage("Friend_ReqeustButtonInFriendDetails2", 0, , , true))
                adbClick_wbb(143, 407)
            else
                adbClick_wbb(243, 258)
            MarkFriendCleanupPending("Daily share friend request")
        }
        if (!CollectionShare_WaitFriendAccepted(friendCode, 90))
            return false
    } else if (state != "friended") {
        LogWarn("CollectionShare: friend check failed for Main (" . state . ")")
        return false
    }

    if (!CollectionShare_FavouriteCurrentProfile())
        return false

    return CollectionShare_EnsureSocial()
}

;-------------------------------------------------------------------------------
; CollectionShare_EnsureExpansionSort - Force expansion-ascending card sort
;
; Opens the sort settings (245,502); ExpansionAscending must be visible in the
; sort menu (231,368-271,392). If absent, clicks the order option (185,381),
; ESCs and retries (max 5 rounds).
;-------------------------------------------------------------------------------
CollectionShare_EnsureExpansionSort() {
    attempts := 0
    Loop {
        attempts += 1
        if (attempts > 5) {
            LogWarn("CollectionShare: could not get ExpansionAscending sort after " . attempts . " attempts")
            return false
        }

        adbClick_wbb(245, 502) ; open sort settings
        start := A_TickCount
        found := false
        Loop {
            if (FindOrLoseImage(231, 368, 271, 392, , "ExpansionAscending", 0, 0)) {
                found := true
                break
            }
            if (((A_TickCount - start) // 1000) >= 5)
                break
            Sleep, 300
        }
        if (found) {
            adbInputEvent("111") ; ESC closes the open sort menu only
            Sleep, 500
            return true
        }

        adbClick_wbb(185, 381) ; choose expansion order (menu closes by itself)
        Sleep, 800
    }
}

;-------------------------------------------------------------------------------
; CollectionShare_EnsureRaritySort - Force rarity-descending card sort
;
; Same retry scheme as EnsureExpansionSort but verifies the RarityAsc needle
; (233,275-270,294) and resorts via (185,281).
;-------------------------------------------------------------------------------
CollectionShare_EnsureRaritySort() {
    attempts := 0
    Loop {
        attempts += 1
        if (attempts > 5) {
            LogWarn("CollectionShare: could not get RarityAsc sort after " . attempts . " attempts")
            return false
        }

        adbClick_wbb(245, 502) ; open sort settings
        start := A_TickCount
        found := false
        Loop {
            if (FindOrLoseImage(233, 275, 270, 294, , "RarityAsc", 0, 0)) {
                found := true
                break
            }
            if (((A_TickCount - start) // 1000) >= 5)
                break
            Sleep, 300
        }
        if (found) {
            adbInputEvent("111") ; ESC closes the open sort menu only
            Sleep, 500
            return true
        }

        adbClick_wbb(185, 281) ; choose rarity order (menu closes by itself)
        Sleep, 800
    }
}

;-------------------------------------------------------------------------------
; CollectionShare_OcrFold - Fold Latin diacritics to ASCII so accented names
;   ("Mysteriöse", "Lüfte", "Puissance Génétique") normalize identically whether
;   the OCR engine reads the accented glyph or its base letter. Multi-char folds
;   (ß->ss, œ->oe, æ->ae) run first; single-char folds map to lowercase ASCII and
;   OcrUpper lifts them afterwards.
;-------------------------------------------------------------------------------
CollectionShare_OcrFold(s) {
    ; "from>to" pairs separated by `n; StrReplace is literal so order is safe.
    static table := "ß>ss`nẞ>ss`nœ>oe`nŒ>oe`næ>ae`nÆ>ae`n"
        . "à>a`ná>a`nâ>a`nã>a`nä>a`nå>a`nā>a`nă>a`ną>a`n"
        . "À>a`nÁ>a`nÂ>a`nÃ>a`nÄ>a`nÅ>a`nĀ>a`nĂ>a`nĄ>a`n"
        . "ç>c`nć>c`nč>c`nÇ>c`nĆ>c`nČ>c`n"
        . "è>e`né>e`nê>e`në>e`nē>e`nĕ>e`nė>e`nę>e`ně>e`n"
        . "È>e`nÉ>e`nÊ>e`nË>e`nĒ>e`nĔ>e`nĖ>e`nĘ>e`nĚ>e`n"
        . "ì>i`ní>i`nî>i`nï>i`nī>i`nĭ>i`nį>i`nı>i`n"
        . "Ì>i`nÍ>i`nÎ>i`nÏ>i`nĪ>i`nĬ>i`nĮ>i`nİ>i`n"
        . "ñ>n`nń>n`nň>n`nÑ>n`nŃ>n`nŇ>n`n"
        . "ò>o`nó>o`nô>o`nõ>o`nö>o`nø>o`nō>o`nŏ>o`nő>o`n"
        . "Ò>o`nÓ>o`nÔ>o`nÕ>o`nÖ>o`nØ>o`nŌ>o`nŎ>o`nŐ>o`n"
        . "ù>u`nú>u`nû>u`nü>u`nū>u`nŭ>u`nů>u`nű>u`nų>u`n"
        . "Ù>u`nÚ>u`nÛ>u`nÜ>u`nŪ>u`nŬ>u`nŮ>u`nŰ>u`nŲ>u`n"
        . "ý>y`nÿ>y`nÝ>y`nŸ>y`n"
        . "š>s`nŠ>s`nž>z`nŽ>z`nď>d`nĎ>d`nť>t`nŤ>t`nĺ>l`nĹ>l`nŕ>r`nŔ>r"
    Loop, Parse, table, `n
        s := StrReplace(s, SubStr(A_LoopField, 1, 1), SubStr(A_LoopField, 3))
    return s
}

;-------------------------------------------------------------------------------
; CollectionShare_OcrNorm - Normalize OCR text for fuzzy expansion matching:
;   fold diacritics, uppercase, keep Unicode letters/numbers (CJK scripts stay
;   matchable), strip everything else.
;-------------------------------------------------------------------------------
CollectionShare_OcrUpper(s) {
    out := ""
    Loop, % StrLen(s) {
        c := SubStr(s, A_Index, 1)
        o := Ord(c)
        out .= (o >= 97 and o <= 122) ? Chr(o - 32) : c
    }
    return out
}

CollectionShare_OcrNorm(s) {
    return RegExReplace(CollectionShare_OcrUpper(CollectionShare_OcrFold(s)), "[^\p{L}\p{N}]", "")
}

;-------------------------------------------------------------------------------
; CollectionShare_JsonUnescape - Decode \uXXXX escapes embedded in the locale
;   JSON values. CJK expansion names are stored entirely as escapes; matching
;   them against real OCR glyphs requires the decoded text. Also covers the
;   \u2019 apostrophe handled previously by a literal StrReplace.
;-------------------------------------------------------------------------------
CollectionShare_JsonUnescape(s) {
    out := "", p := 1
    While (q := RegExMatch(s, "i)\\u([0-9a-f]{4})", m, p)) {
        out .= SubStr(s, p, q - p) . Chr("0x" . m1)
        p := q + 6
    }
    return out . SubStr(s, p)
}

;-------------------------------------------------------------------------------
; CollectionShare_OcrNameBlocks - Group OCR words into expansion-name candidates.
;
; The picker is a 2-column grid; each tile prints its name as one or more text
; lines followed by a "N/M" counter ~40px lower. Words are bucketed by column,
; clustered into rows (same column, vertical gap <= 10px, words kept in x
; order), then rows are clustered into name blocks (vertical gap <= 30px: name
; lines sit ~18px apart, the counter ~41px below the last name line). Returns
; blocks with the joined text, normalized text and bounding-box center.
;-------------------------------------------------------------------------------
CollectionShare_OcrNameBlocks(words) {
    ; Flatten to sortable "col|y|x|w|h|idx|text" lines, zero-padded for lexical sort
    keys := ""
    idx := 0
    for _, w in words {
        t := Trim(w.text)
        if (t = "")
            continue
        t := StrReplace(StrReplace(StrReplace(t, "`t", " "), "`n", " "), "`r", " ")
        col := (w.x + w.w / 2 < 270) ? "1" : "2"
        yk := SubStr("000" . Round(w.y), -3)
        xk := SubStr("000" . Round(w.x), -3)
        wk := SubStr("00" . Round(w.w), -3)
        hk := SubStr("00" . Round(w.h), -3)
        idx++
        keys .= col . "`t" . yk . "`t" . xk . "`t" . wk . "`t" . hk . "`t" . idx . "`t" . t . "`n"
    }
    if (keys = "")
        return []
    Sort, keys
    items := []
    Loop, Parse, keys, `n, `r
    {
        if (A_LoopField = "")
            continue
        StringSplit, p, A_LoopField, "`t"
        items.Push({col: p1, y: p2 + 0, x: p3 + 0, w: p4 + 0, h: p5 + 0, text: p7})
    }
    ; Pass 1: cluster words into rows per column
    rows := []
    curRow := ""
    for _, it in items {
        if (curRow != "" and (it.col != curRow.col or it.y - curRow.lastY > 10)) {
            rows.Push(curRow)
            curRow := ""
        }
        if (curRow = "") {
            curRow := {col: it.col, y: it.y, words: [], minX: it.x, minY: it.y, maxX: it.x + it.w, maxY: it.y + it.h, lastY: it.y}
        }
        nw := []
        inserted := false
        for _, wd in curRow.words {
            if (!inserted and it.x < wd.x) {
                nw.Push(it)
                inserted := true
            }
            nw.Push(wd)
        }
        if (!inserted)
            nw.Push(it)
        curRow.words := nw
        if (it.x < curRow.minX)
            curRow.minX := it.x
        if (it.y < curRow.minY)
            curRow.minY := it.y
        if (it.x + it.w > curRow.maxX)
            curRow.maxX := it.x + it.w
        if (it.y + it.h > curRow.maxY)
            curRow.maxY := it.y + it.h
        curRow.lastY := it.y
    }
    if (curRow != "")
        rows.Push(curRow)
    ; Pass 2: cluster rows into name blocks per column
    blocks := []
    cur := ""
    for _, r in rows {
        if (cur != "" and (r.col != cur.col or r.y - cur.lastY > 30)) {
            blocks.Push(cur)
            cur := ""
        }
        if (cur = "") {
            cur := {col: r.col, text: "", minX: r.minX, minY: r.minY, maxX: r.maxX, maxY: r.maxY, lastY: r.y}
        }
        rtext := ""
        for _, wd in r.words
            rtext .= (rtext = "" ? "" : " ") . wd.text
        cur.text .= (cur.text = "" ? "" : " ") . rtext
        if (r.minX < cur.minX)
            cur.minX := r.minX
        if (r.minY < cur.minY)
            cur.minY := r.minY
        if (r.maxX > cur.maxX)
            cur.maxX := r.maxX
        if (r.maxY > cur.maxY)
            cur.maxY := r.maxY
        cur.lastY := r.y
    }
    if (cur != "")
        blocks.Push(cur)
    result := []
    for _, b in blocks {
        norm := CollectionShare_OcrNorm(b.text)
        ; CJK names are short ("오시리즈", "天空の支配者"): weigh non-ASCII
        ; glyphs double - they carry as much information as ~2 Latin chars.
        normLen := 0
        Loop, Parse, norm
            normLen += (Ord(A_LoopField) > 127) ? 2 : 1
        ; Series headers must survive the length filter: "C系列"/"B系列" are
        ; only 3 glyphs, but they anchor the whole grid map.
        isHeader := RegExMatch(b.text, "i)seri[eèé]s?|シリーズ|系列|시리즈")
        if ((normLen < 6 and !isHeader) or InStr(b.text, "/") or RegExMatch(b.text, "^\d+$")
            or RegExMatch(b.text, "^[\d\s/\\Iil|]+$")) ; counter junk ("209 I 402") is not a name
            continue
        result.Push({text: b.text, norm: norm, cx: (b.minX + b.maxX) / 2, cy: (b.minY + b.maxY) / 2, x1: b.minX, y1: b.minY, x2: b.maxX, y2: b.maxY})
    }
    return result
}

;-------------------------------------------------------------------------------
; CollectionShare_LocaleForLang - Map a game/ptcgpb language code to the
;   pocket_tcg_resources locale file suffix and the Windows OCR language tag.
;   Returns "" when the language has no usable name database (caller falls
;   back to English).
;-------------------------------------------------------------------------------
CollectionShare_LocaleForLang(lang) {
    lang := Trim(lang)
    if (RegExMatch(lang, "i)^en"))
        return {file: "en_US", ocr: "en"}
    if (RegExMatch(lang, "i)^it"))
        return {file: "it_IT", ocr: "it"}
    if (RegExMatch(lang, "i)^de"))
        return {file: "de_DE", ocr: "de"}
    if (RegExMatch(lang, "i)^fr"))
        return {file: "fr_FR", ocr: "fr"}
    if (RegExMatch(lang, "i)^es"))
        return {file: "es_ES", ocr: "es"}
    if (RegExMatch(lang, "i)^pt"))
        return {file: "pt_BR", ocr: "pt"}
    if (RegExMatch(lang, "i)^(ja|jp)"))
        return {file: "ja_JP", ocr: "ja"}
    if (RegExMatch(lang, "i)^ko"))
        return {file: "ko_KR", ocr: "ko"}
    if (RegExMatch(lang, "i)^zh"))
        return {file: "zh_TW", ocr: "zh-Hant-TW"} ; the game only ships traditional Chinese
    return ""
}

;-------------------------------------------------------------------------------
; CollectionShare_OcrLocale - Locale + OCR engine for the account's game
;   language. Falls back to English when the language is unknown or has no
;   name database - same behaviour as before localization support.
;-------------------------------------------------------------------------------
CollectionShare_OcrLocale() {
    global session
    lang := Trim(session.get("language"))
    if (lang = "") {
        accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), session.get("loadedAccount"))
        lang := Trim(accountMeta["language"])
    }
    loc := CollectionShare_LocaleForLang(lang)
    if (loc = "")
        loc := {file: "en_US", ocr: "en"}
    return loc
}

;-------------------------------------------------------------------------------
; CollectionShare_ExpansionList - All non-SP expansions as {code, name, norm}
;   parsed once per locale from Helper\<locale>.json (same source as the share
;   settings GUI). Names are localized so the picker can be matched in the
;   account's own language; codes stay language-independent.
;-------------------------------------------------------------------------------
CollectionShare_ExpansionList(locale := "en_US") {
    global CollectionShare_expansionLists
    if (!IsObject(CollectionShare_expansionLists))
        CollectionShare_expansionLists := {}
    cached := CollectionShare_expansionLists[locale]
    if (cached != "")
        return cached
    list := []
    path := getScriptBaseFolder() . "\Helper\" . locale . ".json"
    if (FileExist(path)) {
        FileRead, txt, %path%
        Loop, 60 {
            idx := A_Index
            if (!RegExMatch(txt, """EXPANSION_NAME_" . idx . """\s*:\s*""([^""]+)""", mc))
                continue
            code := mc1
            if (code = "" or SubStr(code, 1, 2) = "SP")
                continue
            name := code
            ; Latin locales use EXPANSION_NAME_LONG_<n>; CJK locales only ship
            ; the _plural variant.
            if (RegExMatch(txt, """EXPANSION_NAME_LONG_" . idx . """\s*:\s*""([^""]+)""", ml)
                || RegExMatch(txt, """EXPANSION_NAME_LONG_" . idx . "_plural""\s*:\s*""([^""]+)""", ml))
                name := CollectionShare_JsonUnescape(ml1)
            ; Always keep the slot even when the localized name is missing or
            ; very short ("幻遊島"/"幻游岛" for A1a): the picker's positional
            ; solver depends on index order, and a code-named entry can never
            ; be confused for a real tile.
            norm := CollectionShare_OcrNorm(name)
            list.Push({code: code, name: name, norm: norm})
        }
    }
    CollectionShare_expansionLists[locale] := list
    return list
}

;-------------------------------------------------------------------------------
; CollectionShare_OcrFindExpansion - Return {x, y} to tap for the expansion at
;   index targetIdx of allNames, or "" when no candidate is confident enough.
;
; The positional solver runs FIRST for every locale: grid cell, series
; headers and the "N/M" card counter are digits and geometry, identical in
; all languages, while localized names (French/German especially) are the
; least reliable evidence OCR produces. Name matching only survives as a
; fallback and always requires a readable, agreeing counter - a confident
; name alone is never allowed to fire a tap.
;
; In the fallback, every name block is assigned to the expansion it matches
; best across ALL names (argmax), so a clearly-read sibling tile (e.g.
; "Deluxe Pack: Mega" for target "Deluxe Pack: ex") can never be tapped for
; the wrong expansion. A block votes for its argmax when either:
;   - score >= 0.72 and (score >= 0.9 or beats runner-up by 0.03), or
;   - score >= 0.45 and beats runner-up by 0.15 (partial OCR reads like
;     "PALDEAN" for "Paldean Wonders" stay safe via the wide margin).
;
; siblingIdx marks same-name tiles ("Deluxe Pack: ex"/"Mega" both OCR as
; "DELUXE PACK"): blocks argmaxing to either sibling are eligible.
;-------------------------------------------------------------------------------
CollectionShare_OcrFindExpansion(words, targetIdx, allNames, siblingIdx := 0, wantTotal := "") {
    blocks := CollectionShare_OcrNameBlocks(words)
    ; Ordered-slice solver first: picker tiles always show consecutive
    ; expansions in DESCENDING index order (left cell = higher index).
    ; Assign every block a grid cell (row, col); series headers pin the map
    ; and readable counters validate it. Language-independent by design.
    slice := CollectionShare_OcrSliceMatch(words, blocks, targetIdx, allNames)
    if (slice != "") {
        LogInfo("CollectionShare: slice match '" . slice.text . "' row=" . slice.row . " col=" . slice.col)
        return {x: Round(slice.cx), y: Round(slice.cy)}
    }
    best := "", bestScore := 0, dbgText := "", dbgScore := 0, dbgName := ""
    for _, b in blocks {
        topIdx := 0, topScore := 0, secondScore := 0
        for i, nm in allNames {
            s := SimilarityScore(b.norm, nm.norm)
            if (s > topScore) {
                secondScore := topScore
                topScore := s
                topIdx := i
            } else if (s > secondScore) {
                secondScore := s
            }
        }
        if (topScore > dbgScore) {
            dbgScore := topScore
            dbgText := b.text
            dbgName := (topIdx > 0) ? allNames[topIdx].name : "?"
        }
        confident := (topScore >= 0.72 and (topScore >= 0.9 or topScore - secondScore >= 0.03))
            or (topScore >= 0.45 and topScore - secondScore >= 0.15)
        if (!confident or (topIdx != targetIdx and (!siblingIdx or topIdx != siblingIdx)))
            continue
        if (wantTotal != "") {
            counter := CollectionShare_OcrCounterBelow(words, b)
            if (counter != "" and CollectionShare_OcrCounterClose(counter, wantTotal) = 0)
                continue
            if (counter == "")
                continue ; no name-only taps: an unreadable counter means wait for a better frame
        }
        if (topScore > bestScore) {
            best := b
            bestScore := topScore
        }
    }
    if (best != "") {
        LogInfo("CollectionShare: OCR match '" . best.text . "' score=" . Round(bestScore, 2) . " counter=" . CollectionShare_OcrCounterBelow(words, best))
        return {x: Round(best.cx), y: Round(best.cy)}
    }
    if (dbgScore > 0)
        LogInfo("CollectionShare: no confident OCR match, best candidate '" . dbgText . "' -> " . dbgName . " score=" . Round(dbgScore, 2))
    return ""
}

;-------------------------------------------------------------------------------
; CollectionShare_OcrSeriesLetter - Series letter ("A"/"B"/"C") of a section
;   header block ("Aシリーズ", "Serie C", "B Series", "系列B"), else "".
;   Header text may OCR in any language; the keyword is stripped and what is
;   left must be exactly one Latin/fullwidth letter.
;-------------------------------------------------------------------------------
CollectionShare_OcrSeriesLetter(text) {
    if (!RegExMatch(text, "i)seri[eèé]s?|シリーズ|系列|시리즈"))
        return ""
    t := RegExReplace(text, "i)seri[eèé]s?|シリーズ|系列|시리즈", "")
    t := RegExReplace(t, "\s", "")
    if (StrLen(t) = 1) {
        c := Ord(t)
        if (c >= 0xFF21 and c <= 0xFF3A)      ; fullwidth A-Z
            return Chr(c - 0xFEE0)
        if (c >= 0xFF41 and c <= 0xFF5A)      ; fullwidth a-z
            return Chr(c - 0xFEE0 - 32)
        if (c >= 97 and c <= 122)
            return Chr(c - 32)
        if (c >= 65 and c <= 90)
            return t
    }
    return "?" ; series keyword but the letter itself is unreadable ("8시리즈" for "B시리즈")
}

;-------------------------------------------------------------------------------
; CollectionShare_SeriesBase / SeriesCount - Highest list index / tile count of
;   the expansions whose code starts with a letter, derived from allNames so
;   future sets need no table updates.
;-------------------------------------------------------------------------------
CollectionShare_SeriesBase(letter, allNames) {
    base := ""
    for i, e in allNames
        if (SubStr(e.code, 1, 1) = letter)
            base := i
    return base
}

CollectionShare_SeriesCount(letter, allNames) {
    cnt := 0
    for _, e in allNames
        if (SubStr(e.code, 1, 1) = letter)
            cnt++
    return cnt
}

;-------------------------------------------------------------------------------
; CollectionShare_OcrSliceMatch - Identify blocks by their position inside the
;   picker's fixed expansion order. Tiles render newest-first, two per row,
;   grouped under "X Series" section headers that pin the grid: the tile row
;   directly below "Bシリーズ" always holds the B series' newest expansion.
;
; Two passes:
;   1. header mode - when a series header is visible, every tile's index is
;      deterministic (seriesBase - 2*j - col); counters only validate.
;   2. offset solver - no header visible: try every candidate index for the
;      top-left cell, scored by counter agreements.
; Row indices are absolute (y/pitch) so an entirely unreadable row cannot
; shift the map. Truncated counter reads ("6" for "69") stay neutral.
; Returns the block for targetIdx or "".
;-------------------------------------------------------------------------------
CollectionShare_OcrBlockArgmax(b, allNames) {
    ; Expansion index the block reads as with the same confidence bar as the
    ; name matcher, else 0. Used as a veto, never as a reason to tap.
    bi := 0, bs := 0, b2 := 0
    for i, nm in allNames {
        s := SimilarityScore(b.norm, nm.norm)
        if (s > bs) {
            b2 := bs, bs := s, bi := i
        } else if (s > b2) {
            b2 := s
        }
    }
    if ((bs >= 0.72 and (bs >= 0.9 or bs - b2 >= 0.03)) or (bs >= 0.45 and bs - b2 >= 0.15))
        return bi
    return 0
}

CollectionShare_SameTileName(codeA, codeB) {
    ; the two Deluxe boosters share one tile name in every locale
    return ((codeA = "A4b" or codeA = "B4b") and (codeB = "A4b" or codeB = "B4b"))
}

CollectionShare_OcrSliceMatch(words, blocks, targetIdx, allNames) {
    if (blocks.Length() = 0)
        return ""
    ; cluster blocks into rows (same visual row: minY within 50px), top first
    ordered := []
    for _, b in blocks
        ordered.Push(b)
    ; insertion sort by minY
    Loop, % ordered.Length() {
        i := A_Index
        while (i > 1 and ordered[i].y1 < ordered[i - 1].y1) {
            t := ordered[i - 1], ordered[i - 1] := ordered[i], ordered[i] := t
            i--
        }
    }
    rows := []
    for _, b in ordered {
        if (rows.Length() = 0 or b.y1 - rows[rows.Length()].y1 > 50)
            rows.Push({y1: b.y1, blocks: []})
        rows[rows.Length()].blocks.Push(b)
    }
    ; Merge fragment rows: a tile's name can split into several OCR blocks
    ; ~60-90px apart (CJK multiline names), which would halve the median
    ; pitch and shift the whole map by a row. Real tile rows are >=~120px
    ; apart; merge closer rows unless either holds a series header.
    merged := []
    for r, row in rows {
        rowHasHdr := false
        for _, b in row.blocks {
            if (CollectionShare_OcrSeriesLetter(b.text) != "") {
                rowHasHdr := true
                break
            }
        }
        if (merged.Length() > 0 and !rowHasHdr and !merged[merged.Length()].hasHdr
            and row.y1 - merged[merged.Length()].y1 <= 95) {
            for _, b in row.blocks
                merged[merged.Length()].blocks.Push(b)
            continue
        }
        merged.Push({y1: row.y1, blocks: row.blocks, hasHdr: rowHasHdr})
    }
    rows := merged
    ; absolute row index = y / median pitch: a missing row leaves a gap in the
    ; indices instead of shifting every block below it
    diffs := []
    Loop, % rows.Length() - 1
        diffs.Push(rows[A_Index + 1].y1 - rows[A_Index].y1)
    Loop, % diffs.Length() {
        i := A_Index
        while (i > 1 and diffs[i] < diffs[i - 1]) {
            t := diffs[i - 1], diffs[i - 1] := diffs[i], diffs[i] := t
            i--
        }
    }
    pitch := (diffs.Length() > 0) ? diffs[Ceil(diffs.Length() / 2)] : 133
    if (pitch <= 0)
        pitch := 133
    rowIdx := []
    for r, row in rows
        rowIdx[r] := Round((row.y1 - rows[1].y1) / pitch)
    n := allNames.Length()
    ; find series headers. OcrSeriesLetter returns a letter, "?" (keyword
    ; reads but the letter glyph is mangled - e.g. "8시리즈"), or "".
    headerAt := {}
    hasHdr := false
    for r, row in rows {
        for _, b in row.blocks {
            L := CollectionShare_OcrSeriesLetter(b.text)
            if (L != "") {
                if (!headerAt.HasKey(rowIdx[r]))
                    headerAt[rowIdx[r]] := L
                hasHdr := true
                break
            }
        }
    }
    cells := []
    for r, row in rows {
        ; A row holding a detected series header is the section divider:
        ; no expansion tile lives on it. Leftover blocks there (decorative
        ; glyphs, fragments) must not be mapped - under the previous letter
        ; they would fabricate phantom cells and corrupt synthetic taps.
        if (headerAt.HasKey(rowIdx[r]))
            continue
        for _, b in row.blocks {
            if (CollectionShare_OcrSeriesLetter(b.text) != "")
                continue
            col := ((b.x1 + b.x2) / 2 < 270) ? 0 : 1
            cells.Push({b: b, off: 2 * rowIdx[r] + col, row: rowIdx[r], col: col})
        }
    }
    if (hasHdr) {
        ; Resolve "?" headers: every candidate letter maps the rows it governs
        ; (until the next header) differently; the letter whose map agrees with
        ; the most readable counters wins. Unresolvable headers become
        ; barriers - tiles under them get no index instead of a wrong one.
        letters := {}
        for _, e in allNames
            letters[SubStr(e.code, 1, 1)] := true
        barrierAt := {}
        for hIdx, L in headerAt {
            if (L != "?")
                continue
            nextH := 9999
            prevH := -9999
            for h2, _ in headerAt
                if (h2 > hIdx and h2 < nextH)
                    nextH := h2
                else if (h2 < hIdx and h2 > prevH)
                    prevH := h2
            bestL := "", bestVotes := 0, bestTies := 0
            for cand, _ in letters {
                base := CollectionShare_SeriesBase(cand, allNames)
                votes := 0
                if (base != "") {
                    for _, c in cells {
                        if (c.row <= hIdx or c.row >= nextH)
                            continue
                        idx := base - 2 * (c.row - hIdx - 1) - c.col
                        if (idx < 1 or idx > n)
                            continue
                        counter := CollectionShare_OcrCounterBelow(words, c.b)
                        if (counter != "" and CollectionShare_OcrCounterClose(counter, CollectionShare_ExpansionCounterTotal(allNames[idx].code)) = 2)
                            votes++
                    }
                }
                ; A header at the top of the frame can also be judged by the
                ; rows above it: they are the tail of the previous series.
                if (prevH = -9999) {
                    ub := CollectionShare_SeriesBase(Chr(Ord(cand) + 1), allNames)
                    uc := CollectionShare_SeriesCount(Chr(Ord(cand) + 1), allNames)
                    if (ub != "" and uc > 0) {
                        for _, c in cells {
                            if (c.row >= hIdx)
                                continue
                            j := Floor((uc - 1) / 2) - (hIdx - c.row - 1)
                            if (j < 0)
                                continue
                            idx := ub - 2 * j - c.col
                            if (idx < 1 or idx > n)
                                continue
                            counter := CollectionShare_OcrCounterBelow(words, c.b)
                            if (counter != "" and CollectionShare_OcrCounterClose(counter, CollectionShare_ExpansionCounterTotal(allNames[idx].code)) = 2)
                                votes++
                        }
                    }
                }
                if (votes > bestVotes) {
                    bestVotes := votes, bestL := cand, bestTies := 1
                } else if (votes = bestVotes and votes > 0) {
                    bestTies++ ; repeated denominators make letter votes tie - an ambiguous header must become a barrier, not an arbitrary pick
                }
            }
            if (bestL != "" and bestTies = 1)
                headerAt[hIdx] := bestL
            else {
                headerAt.Delete(hIdx)
                barrierAt[hIdx] := true
            }
        }
        ; deterministic map under section headers
        boundAt := {}
        for hIdx, L in headerAt
            boundAt[hIdx] := L
        for hIdx, _ in barrierAt
            boundAt[hIdx] := "!"
        firstBound := ""
        for hIdx, _ in boundAt
            if (firstBound = "" or hIdx < firstBound)
                firstBound := hIdx
        firstLetter := (firstBound != "" and boundAt[firstBound] != "!") ? boundAt[firstBound] : ""
        upBase := "", upCount := 0
        if (firstLetter != "") {
            upBase := CollectionShare_SeriesBase(Chr(Ord(firstLetter) + 1), allNames)
            upCount := CollectionShare_SeriesCount(Chr(Ord(firstLetter) + 1), allNames)
        }
        mapped := []
        for _, c in cells {
            gov := ""
            for hIdx, _ in boundAt
                if (hIdx < c.row and (gov = "" or hIdx > gov))
                    gov := hIdx
            if (gov != "") {
                if (boundAt[gov] = "!")
                    continue ; under an unresolved header: leave unmapped
                c.idx := CollectionShare_SeriesBase(boundAt[gov], allNames) - 2 * (c.row - gov - 1) - c.col
            } else if (firstLetter != "" and upBase != "" and upCount > 0) {
                j := Floor((upCount - 1) / 2) - (firstBound - c.row - 1)
                if (j >= 0)
                    c.idx := upBase - 2 * j - c.col
            }
            if (c.idx != "")
                mapped.Push(c)
        }
        ; counters validate the map: a wrong map would disagree on most cells,
        ; so agreements must dominate. Truncated reads stay neutral; a clean
        ; mismatch on the target tile itself always vetoes the tap.
        agree := 0, disagree := 0, target := "", targetBad := false
        hdrDbg := ""
        for hIdx, L in boundAt
            hdrDbg .= L . "@" . hIdx . " "
        for _, c in mapped {
            if (c.idx < 1 or c.idx > n)
                continue
            counter := CollectionShare_OcrCounterBelow(words, c.b)
            if (counter != "") {
                prox := CollectionShare_OcrCounterClose(counter, CollectionShare_ExpansionCounterTotal(allNames[c.idx].code))
                if (prox = 2)
                    agree++
                else if (prox = 0) {
                    disagree++
                    if (c.idx = targetIdx)
                        targetBad := true
                }
            }
            if (c.idx = targetIdx) {
                target := c
                ; the target tile's own name is decisive: counters collide
                ; across sets (A1 and B1 are both /226), a confident read of
                ; a different expansion always vetoes the tap
                ni := CollectionShare_OcrBlockArgmax(c.b, allNames)
                if (ni > 0 and ni != targetIdx
                    and !CollectionShare_SameTileName(allNames[ni].code, allNames[targetIdx].code))
                    targetBad := true
            }
        }
        cellDbg := ""
        for _, c in mapped
            cellDbg .= c.idx . "@" . c.row . "," . c.col . " "
        LogInfo("CollectionShare: slice hdr[" . Trim(hdrDbg) . "] pitch=" . pitch . " cells[" . Trim(cellDbg) . "] agree=" . agree . " disagree=" . disagree . (targetBad ? " TARGET-VETO" : ""))
        if (agree >= 2 and agree > disagree and !targetBad) {
            if (target != "") {
                target.b.row := target.row
                target.b.col := target.col
                return target.b
            }
            ; The target's tile produced no name block: the validated map still
            ; pins its grid position - synthesize the tap from a mapped cell
            ; in the same section (positions stay linear within a series).
            tLetter := SubStr(allNames[targetIdx].code, 1, 1)
            for _, c in mapped {
                if (c.idx < 1 or c.idx > n)
                    continue
                if (SubStr(allNames[c.idx].code, 1, 1) != tLetter)
                    continue
                p := 2 * c.row + c.col + (c.idx - targetIdx)
                if (p < 0)
                    continue
                rIdx := Floor(p / 2), colT := p - 2 * rIdx
                cy := Round(rows[1].y1 + rIdx * pitch + 25)
                if (cy > 80 and cy < 900)
                    return {text: "cell(" . rIdx . "," . colT . ")", cx: (colT ? 390 : 150), cy: cy, row: rIdx, col: colT}
            }
        }
        return ""
    }
    ; offset solver (no header visible): try every candidate index for the
    ; top-left cell. Counters score +10 match / -10 mismatch; truncated reads
    ; stay neutral so a misread cannot sink a correct alignment.
    bestS := 0, bestScore := 0
    Loop, % n {
        s := A_Index
        valid := true, score := 0, anchors := 0
        for _, c in cells {
            idx := s - c.off
            if (idx < 1 or idx > n) {
                valid := false
                break
            }
            counter := CollectionShare_OcrCounterBelow(words, c.b)
            if (counter != "") {
                prox := CollectionShare_OcrCounterClose(counter, CollectionShare_ExpansionCounterTotal(allNames[idx].code))
                if (prox = 2) {
                    anchors++
                    score += 10
                } else if (prox = 0) {
                    score -= 10
                }
            } else {
                score += SimilarityScore(c.b.norm, allNames[idx].norm)
            }
        }
        if (valid and anchors >= 2 and score > bestScore) {
            bestScore := score
            bestS := s
        }
    }
    if (bestS = 0)
        return ""
    for _, c in cells {
        if (bestS - c.off = targetIdx) {
            ni := CollectionShare_OcrBlockArgmax(c.b, allNames)
            if (ni > 0 and ni != targetIdx
                and !CollectionShare_SameTileName(allNames[ni].code, allNames[targetIdx].code))
                return "" ; the tile confidently reads as another expansion
            c.b.row := c.row
            c.b.col := c.col
            return c.b
        }
    }
    ; Target's tile produced no block but the alignment is validated:
    ; synthesize the tap point from its grid offset.
    off := bestS - targetIdx
    if (off >= 0) {
        rIdx := Floor(off / 2), colT := off - 2 * rIdx
        cy := Round(rows[1].y1 + rIdx * pitch + 25)
        if (cy > 80 and cy < 900)
            return {text: "cell(" . rIdx . "," . colT . ")", cx: (colT ? 390 : 150), cy: cy, row: rIdx, col: colT}
    }
    return ""
}

;-------------------------------------------------------------------------------
; CollectionShare_RapidOcr - OCR via RapidOCR-json.exe (PP-OCR ONNX models).
;   Reads stylized tile text that Windows.Media.Ocr silently drops and does it
;   at native 540x960 resolution. Returns the same [{text, x, y, w, h}]
;   format as ocr(), or "" on failure.
;-------------------------------------------------------------------------------
CollectionShare_RapidOcrLang(ocrTag) {
    ; The default ch_PP-OCRv4 recognizer already covers the Latin alphabet
    ; (it reads the English/Italian/etc tile names fine). CJK locales get
    ; their dedicated rec model + keyset shipped inside rapidocr\models.
    if (ocrTag = "ja")
        return " --rec rec_japan_PP-OCRv3_infer.onnx --keys dict_japan.txt"
    if (ocrTag = "ko")
        return " --rec rec_korean_PP-OCRv3_infer.onnx --keys dict_korean.txt"
    if (ocrTag ~ "^zh")
        return " --rec rec_chinese_cht_PP-OCRv3_infer.onnx --keys dict_chinese_cht.txt"
    return ""
}

;-------------------------------------------------------------------------------
; CollectionShare_CropImage - Save a (x,y,w,h) slice of a PNG via GDI+. Used to
; OCR a small screen region instead of the full frame (much faster).
;-------------------------------------------------------------------------------
CollectionShare_CropImage(srcFile, dstFile, x, y, w, h) {
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

CollectionShare_RapidOcr(shotFile, ocrTag := "", cX := 0, cY := 0, cW := 0, cH := 0) {
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
        if (CollectionShare_CropImage(shotFile, cropFile, cX, cY, cW, cH))
            ocrFile := cropFile
        else
            cX := 0, cY := 0 ; crop failed: fall back to the full frame
    }
    cmd := """" . exe . """ --image_path """ . ocrFile . """ --ensureLogger 0 --doAngle 0 --mostAngle 0" . CollectionShare_RapidOcrLang(ocrTag)
    outFile := A_Temp . "\rapidocr_" . session.get("scriptName") . ".json"
    RunWait, %ComSpec% /c cd /d "%exeDir%" && %cmd% > "%outFile%", , Hide
    if (!FileExist(outFile))
        return ""
    FileRead, json, *P65001 %outFile% ; RapidOCR emits UTF-8 without BOM
    FileDelete, %outFile%
    ; extract each {"box":[[x,y]x4],"score":N,"text":"T"} element
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

;-------------------------------------------------------------------------------
; CollectionShare_OcrCounterBelow - Total ("M" of "N/M") of the card counter
;   printed under a name block, or "" when unreadable. The counter sits ~55px
;   below the last name line; OCR may return it as one word ("209/402") or two
;   ("34/" + "353"), so the zone text is joined before matching.
;-------------------------------------------------------------------------------
CollectionShare_OcrCounterBelow(words, block, ByRef isClean := "") {
    txt := ""
    for _, w in words {
        if (w.y >= block.y2 + 5 and w.y <= block.y2 + 90 and w.x >= block.x1 - 20 and w.x <= block.x2 + 20)
            txt .= w.text . " "
    }
    if (RegExMatch(txt, "(\d+)\s*[/\\Iil|]\s*(\d+)", m)) { ; OCR reads the slash as I/l/| on the small counter font
        isClean := true
        return m2
    }
    ; Slash lost entirely ("871131" for "87/131", "169" for "16/69"): return
    ; the raw digits, OcrCounterClose scores the tail as the denominator.
    if (RegExMatch(txt, "(\d{3,})", m))
        return m1
    return ""
}

;-------------------------------------------------------------------------------
; CollectionShare_ExpansionCounterTotal - Fixed per-set total ("M" of the
;   picker's "N/M" card counter). Derived live from Helper\cardmap.json +
;   cardmaster.json (verified 23/23 against the picker), with the static
;   table kept as fallback and runtime-learned values covering sets not yet
;   in cardmap. Many sets share the same total, so the counter verifies
;   rather than identifies: a readable counter that differs rejects the tile.
;-------------------------------------------------------------------------------
CollectionShare_ExpansionCounterTotal(code) {
    static table := "A1=226,A1a=68,A2=155,A2a=75,A2b=72,A3=155,A3a=69,A3b=69,A4=161,A4a=71,A4b=353,B1=226,B1a=69,B2=155,B2a=93,B2b=69,B3=155,B3a=74,B3b=69,B4=155,B4a=72,B4b=402,C1=131"
    static totals := ""
    if (totals = "")
        totals := CollectionShare_DeriveCounterTotals()
    if (IsObject(totals) and totals.HasKey(code))
        return totals[code]
    IniRead, v, % getScriptBaseFolder() . "\expansion_counters.ini", ExpansionCounters, %code%, %A_Space%
    if (v != "")
        return v
    if (RegExMatch(table, "(?:^|,)" . code . "=(\d+)(?:,|$)", m))
        return m1
    return ""
}

; M equals the highest CollectionNumber among a set's base cards: secret
; rares (cardmaster Rarity >= 500) always occupy the tail of the collection
; numbering, so M = minSecretNumber - 1 (maxNum when the set has none).
CollectionShare_DeriveCounterTotals() {
    cmPath := getScriptBaseFolder() . "\Helper\cardmaster.json"
    mapPath := getScriptBaseFolder() . "\Helper\cardmap.json"
    if (!FileExist(cmPath) or !FileExist(mapPath))
        return ""
    FileRead, cm, %cmPath%
    FileRead, mp, %mapPath%
    rarity := {}
    pos := 1
    re := """([^""]+)"":\s*\{[^{]*?""Rarity"":\s*(\d+)"
    While (p := RegExMatch(cm, re, m, pos)) {
        rarity[m1] := m2 + 0
        pos := p + 1
    }
    perSet := {}
    pos := 1
    re2 := """([^""]+)"":\s*\{\s*""CollectionNumber"":\s*(\d+),\s*""ExpansionID"":\s*""([^""]+)"""
    While (p := RegExMatch(mp, re2, m, pos)) {
        eid := m3, cn := m2 + 0
        if (!perSet.HasKey(eid))
            perSet[eid] := {minSecret: 0, maxNum: 0}
        t := perSet[eid]
        if (cn > t.maxNum)
            t.maxNum := cn
        r := rarity[m1]
        if (r != "" and r >= 500 and (t.minSecret = 0 or cn < t.minSecret))
            t.minSecret := cn
        pos := p + 1
    }
    totals := {}
    for eid, t in perSet
        totals[eid] := (t.minSecret > 0) ? (t.minSecret - 1) : t.maxNum
    return totals
}

CollectionShare_ExpansionCounterLearn(code, total) {
    ; Only clean "N/M" reads are learned: a misread total would poison the
    ; veto checks on every future solve.
    if (code = "" or total = "" or !RegExMatch(total, "^\d{2,3}$"))
        return
    if (CollectionShare_ExpansionCounterTotal(code) != "")
        return ; seed table or already learned - totals never change
    IniWrite, %total%, % getScriptBaseFolder() . "\expansion_counters.ini", ExpansionCounters, %code%
    LogInfo("CollectionShare: learned counter total " . code . "=" . total)
}

;-------------------------------------------------------------------------------
; CollectionShare_OcrCounterClose - How well a read counter matches the
;   expected total: 2 exact, 1 plausible misread (truncated like "6" for "69",
;   or a single-digit swap like "89" for "69" - common on the subscript font),
;   0 clean mismatch.
;-------------------------------------------------------------------------------
CollectionShare_OcrCounterClose(read, expected) {
    if (read = expected)
        return 2
    ; Slash-dropped counter reads are longer than the total ("871131" for
    ; "87/131"): score only the tail - the numerator is OCR-dependent junk.
    if (StrLen(read) > StrLen(expected) and RegExMatch(read, "^\d+$"))
        read := SubStr(read, -(StrLen(expected) - 1))
    if (read = expected)
        return 2
    if (StrLen(read) < StrLen(expected)
        and (SubStr(expected, 1, StrLen(read)) = read
        or SubStr(expected, -(StrLen(read) - 1)) = read))
        return 1
    if (StrLen(read) = StrLen(expected)) {
        diffs := 0
        Loop, % StrLen(read)
            if (SubStr(read, A_Index, 1) != SubStr(expected, A_Index, 1))
                diffs++
        if (diffs = 1)
            return 1
    }
    return 0
}

;-------------------------------------------------------------------------------
; CollectionShare_ExpansionName - English display name for a carddb expansion
;   code (e.g. "A1" -> "Genetic Apex") from Helper\en_US.json. Returns "" when
;   the code or file is missing. SP entries are ignored.
;-------------------------------------------------------------------------------
CollectionShare_ExpansionName(code) {
    path := getScriptBaseFolder() . "\Helper\en_US.json"
    if (!FileExist(path))
        return ""
    FileRead, txt, %path%
    Loop, 60 {
        idx := A_Index
        if (!RegExMatch(txt, """EXPANSION_NAME_" . idx . """\s*:\s*""([^""]+)""", mc))
            continue
        if (mc1 != code or SubStr(mc1, 1, 2) = "SP")
            continue
        if (RegExMatch(txt, """EXPANSION_NAME_LONG_" . idx . """\s*:\s*""([^""]+)""", ml))
            return StrReplace(ml1, "\u2019", "'")
    }
    return ""
}

;-------------------------------------------------------------------------------
; CollectionShare_SelectExpansion - Scroll the expansion list until the target
; expansion name is read by OCR, then click it.
;
; Scroll distance is nondeterministic, so the tile position is never assumed:
; after every swipe a native 540x960 screencap is OCR'd and the picker is
; re-identified, so no per-expansion image needle is needed. expansion is the
; carddb code (e.g. "A1"); its display name comes from Helper\en_US.json via
; CollectionShare_ExpansionName.
; Returns true once the tile is clicked, false after maxScrolls swipes.
;-------------------------------------------------------------------------------
CollectionShare_SelectExpansion(expansion, maxScrolls := 10) {
    global session
    expansion := RegExReplace(expansion, "^ShareExpansion_", "") ; callers may pass the old needle-style name
    locale := CollectionShare_OcrLocale()
    allNames := CollectionShare_ExpansionList(locale.file)
    targetIdx := 0
    targetName := ""
    for i, e in allNames {
        if (e.code = expansion) {
            targetIdx := i
            targetName := e.name
            break
        }
    }
    if (targetIdx = 0) {
        LogWarn("CollectionShare: unknown expansion code: " . expansion)
        return false
    }
    ; Same-name siblings ("Deluxe Pack: ex"/"Mega") share one OCR name: blocks
    ; argmaxing to either are eligible and the card counter picks the right one.
    siblingIdx := 0
    wantTotal := CollectionShare_ExpansionCounterTotal(expansion)
    if (expansion = "A4b" or expansion = "B4b") {
        sibCode := (expansion = "A4b") ? "B4b" : "A4b"
        for i, e in allNames {
            if (e.code = sibCode) {
                siblingIdx := i
                break
            }
        }
    }
    shotFile := A_Temp . "\expsel_" . session.get("scriptName") . ".png"
    prevSig := "", reversed := false
    Loop, % maxScrolls + 1 {
        CreateStatusMessage("Searching " . targetName . "...")
        cmd := """" . session.get("adbPath") . """ -s " . AdbAddress() . " exec-out screencap -p > """ . shotFile . """"
        RunWait, %ComSpec% /c "%cmd%", , Hide
        words := CollectionShare_RapidOcr(shotFile, locale.ocr)
        if (IsObject(words)) {
            match := CollectionShare_OcrFindExpansion(words, targetIdx, allNames, siblingIdx, wantTotal)
            if (match != "") {
                adbWriteRaw("input tap " . match.x . " " . match.y)
                return true
            }
            sig := ""
            for _, w in words
                sig .= w.text . "@" . Round(w.x / 8) . "," . Round(w.y / 8) . "|" ; positions included: identical text at a shifted scroll offset must not read as "list end"
            if (sig != "" and sig = prevSig) {
                if (reversed)
                    break ; scanned both directions, target really absent
                reversed := true
                LogInfo("CollectionShare: list end reached, scrolling back up for " . targetName)
            } else {
                prevSig := sig
            }
        }
        if (A_Index > maxScrolls)
            break
        CreateStatusMessage(targetName . " not visible, scrolling list...")
        if (reversed)
            adbSwipe("8 350 8 650 300") ; scroll back up toward the top
        else
            adbSwipe("8 650 8 250 300") ; ~3 tiles per swipe, away from sheet edges
        adbWriteRaw("input tap 8 500") ; tap the left margin to halt inertial scrolling
        Sleep, 500 ; let the list fully settle before the next screencap
    }
    LogWarn("CollectionShare: " . targetName . " not found after " . maxScrolls . " scrolls")
    return false
}

;-------------------------------------------------------------------------------
; CollectionShare_ChooseExpansion - Open "View Other Booster Packs" and select
;   the expansion logo tile. The booster sheet covers the magnifier bar once
;   open; caller re-verifies the card screen afterwards.
;-------------------------------------------------------------------------------
CollectionShare_ChooseExpansion(expansion) {
    Delay(4) ; let the card screen settle before tapping
    adbWriteRaw("input tap 270 622") ; View Other Booster Packs (device px)
    pickerStart := A_TickCount
    Loop {
        if (!FindOrLoseImage(232, 126, 255, 144, , "ShareMagnifier", 0, 0))
            return CollectionShare_SelectExpansion(expansion)
        if (((A_TickCount - pickerStart) // 1000) >= 10)
            return false
        Sleep, 400
    }
}

;-------------------------------------------------------------------------------
; CollectionShare_GotoCardSelect - From the Social hub, open the daily share
;   flow down to the card-selection screen (magnifier). Returns true once the
;   screen is up, "lost" when the Main already received today's share, false
;   on navigation failure.
;-------------------------------------------------------------------------------
CollectionShare_GotoCardSelect(ignoreAlreadyShared := false) {
    ; Tap Share only while positively on the Social hub, retry on a missed tap
    Loop, 3 {
        if (IsSocialTabActiveOnHub(0))
            adbClick_wbb(77, 407) ; Share button in Social
        if (CollectionShare_WaitScreenNeedle("Share", 34, 347, 63, 373, 8))
            break
        if (A_Index = 3) {
            LogWarn("CollectionShare: Share screen not detected")
            return false
        }
    }

    ; Open the shareable-friend list; retry the tap only while the Share
    ; screen is still up on a missed tap
    friendListOk := false
    Loop, 3 {
        if (FindOrLoseImage(34, 347, 63, 373, , "Share", 0, 0))
            adbClick_wbb(137, 425) ; first Share button -> friend list
        if (CollectionShare_WaitScreenNeedle("ShareAvailable", 239, 169, 256, 196, 7)) {
            friendListOk := true
            break
        }
    }
    if (!friendListOk) {
        LogWarn("CollectionShare: ShareAvailable not detected")
        return false
    }

    ; Main already received a share today: the day is lost, no point retrying
    if (!ignoreAlreadyShared and CollectionShare_WaitScreenNeedle("AlreadyShared", 246, 144, 255, 167, 2)) {
        LogWarn("CollectionShare: Main already received today's share, aborting")
        return "lost"
    }

    ; Select the first shareable friend (favourited Main on top); retry the
    ; tap only while the friend list is still up on a missed tap
    Loop, 3 {
        if (FindOrLoseImage(239, 169, 256, 196, , "ShareAvailable", 0, 0))
            adbClick_wbb(210, 185)
        if (CollectionShare_WaitScreenNeedle("ShareMagnifier", 232, 126, 255, 144, 7))
            return true
    }
    LogWarn("CollectionShare: card selection screen not detected")
    return false
}

;-------------------------------------------------------------------------------
; CollectionShare_CardNameLocalized - cardId -> display name in the given locale
;   file. cardmaster maps cardId to a CARD_NAME_n key; Latin locales store the
;   value under the key itself, CJK locales only under the _plural suffix.
;-------------------------------------------------------------------------------
CollectionShare_CardNameLocalized(cardId, localeFile) {
    static cache := ""
    if (cache = "")
        cache := {}
    key := localeFile . "|" . cardId
    if (cache.HasKey(key))
        return cache[key]

    name := ""
    cmPath := getScriptBaseFolder() . "\Helper\cardmaster.json"
    locPath := getScriptBaseFolder() . "\Helper\" . localeFile . ".json"
    if (FileExist(cmPath) && FileExist(locPath)) {
        FileRead, cm, %cmPath%
        if (RegExMatch(cm, "s)""" . cardId . """\s*:\s*\{[^}]*?""Name""\s*:\s*""([^""]+)""", m)) {
            if (!RegExMatch(m1, "^CARD_NAME_\d+$")) {
                name := m1 ; cardmaster already stores a literal name
            } else {
                FileRead, loc, %locPath%
                if (RegExMatch(loc, """" . m1 . """\s*:\s*""((?:[^""\\]|\\.)*)""", nm)
                    || RegExMatch(loc, """" . m1 . "_plural""\s*:\s*""((?:[^""\\]|\\.)*)""", nm))
                    name := CollectionShare_JsonUnescape(nm1)
            }
        }
    }
    cache[key] := name
    return name
}

;-------------------------------------------------------------------------------
; CollectionShare_VerifyPreviewCard - The StartShare preview prints the chosen
;   card's name on the card itself, in a fixed band between the rarity badge
;   and the HP value. Read it via OCR and compare with the task target: a real
;   mismatch aborts before the Share button is touched (returns false), while
;   an unverifiable check (OCR unavailable, name unresolved, nothing read) only
;   warns and keeps the previous unverified behaviour (returns "").
;-------------------------------------------------------------------------------
CollectionShare_VerifyPreviewCard(cardId) {
    global session
    if (cardId = "")
        return ""
    locale := CollectionShare_OcrLocale()
    expected := CollectionShare_CardNameLocalized(cardId, locale.file)
    if (expected = "") {
        LogWarn("CollectionShare: no localized name for " . cardId . " (" . locale.file . "), skipping preview check")
        return ""
    }

    shotFile := A_Temp . "\shareverify_" . session.get("scriptName") . ".png"
    cmd := """" . session.get("adbPath") . """ -s " . AdbAddress() . " exec-out screencap -p > """ . shotFile . """"
    RunWait, %ComSpec% /c "%cmd%", , Hide
    words := CollectionShare_RapidOcr(shotFile, locale.ocr)
    if (!IsObject(words)) {
        LogWarn("CollectionShare: OCR unavailable, skipping preview check")
        return ""
    }
    LogInfo("CollectionShare: preview OCR words=" . words.Length())
    ; Collect the words inside the card-name band, ordered left to right
    keys := "", band := {}
    for i, w in words {
        cx := w.x + w.w / 2
        cy := w.y + w.h / 2
        if (cy >= 190 and cy <= 240 and cx >= 150 and cx <= 345) {
            keys .= SubStr("000" . Round(w.x), -3) . "|" . i . "`n"
            band[i] := w
        }
    }
    Sort, keys
    bandTxt := ""
    Loop, Parse, keys, `n, `r
        if (p := InStr(A_LoopField, "|"))
            bandTxt .= band[SubStr(A_LoopField, p + 1) + 0].text

    if (bandTxt = "") {
        LogWarn("CollectionShare: no card name read on preview, skipping check")
        return ""
    }
    if (CollectionShare_OcrNorm(bandTxt) = CollectionShare_OcrNorm(expected))
        return true
    LogWarn("CollectionShare: preview card mismatch - expected '" . expected . "', read '" . bandTxt . "'")
    return false
}

;-------------------------------------------------------------------------------
; CollectionShare_PerformShare - In-game share flow once claim is won
;-------------------------------------------------------------------------------
CollectionShare_PerformShare(sortMode := "expansion", expansion := "", cardId := "") {
    global session

    session.set("failSafe", A_TickCount)

    navResult := CollectionShare_GotoCardSelect()
    if (navResult != true) {
        if (navResult = "lost")
            return "lost"
        return false
    }

    ; 1x for the whole remaining flow (sorting clicks + final swipe)
    SetGameSpeed(1)

    if (expansion != "") {
        if (!CollectionShare_ChooseExpansion(expansion)
            || !CollectionShare_WaitScreenNeedle("ShareMagnifier", 232, 126, 255, 144, 15)) {
            LogWarn("CollectionShare: expansion select failed for " . expansion)
            SetConfiguredGameSpeed()
            return false
        }
    }

    sortOk := (sortMode = "rarity") ? CollectionShare_EnsureRaritySort() : CollectionShare_EnsureExpansionSort()
    if (!sortOk) {
        SetConfiguredGameSpeed()
        return false
    }
    Sleep, 500

    adbClick_wbb(50, 445) ; first card in list
    if (!CollectionShare_WaitScreenNeedle("StartShare", 178, 440, 194, 481, 15)) {
        LogWarn("CollectionShare: StartShare not detected")
        SetConfiguredGameSpeed()
        return false
    }

    ; The preview shows the card name: verify it is the task target before
    ; touching Share. false = confirmed wrong card, abort.
    if (CollectionShare_VerifyPreviewCard(cardId) = false) {
        SetConfiguredGameSpeed()
        return false
    }

    adbClick_wbb(138, 462) ; Share
    if (!CollectionShare_WaitScreenNeedle("ConfirmShare", 237, 343, 252, 385, 15)) {
        LogWarn("CollectionShare: ConfirmShare not detected")
        SetConfiguredGameSpeed()
        return false
    }

    adbClick_wbb(192, 364) ; first Ok

    ; Wait for either the optional second-Ok dialog or the swipe screen.
    ; ConfirmShare2 can false-match during screen transition, so keep polling
    ; and click its Ok only while the needle stays visible.
    okStart := A_TickCount
    confirmAttempts := 0
    Loop {
        if (FindOrLoseImage(243, 78, 263, 140, , "ShareSwipe", 0, 0))
            break
        if (FindOrLoseImage(241, 363, 251, 399, , "ConfirmShare2", 0, 0)) {
            confirmAttempts += 1
            if (confirmAttempts > 4) {
                LogWarn("CollectionShare: ConfirmShare2 still visible after " . confirmAttempts . " clicks")
                SetConfiguredGameSpeed()
                return false
            }
            adbClick_wbb(198, 382) ; second Ok (optional dialog)
            Sleep, 600
            continue
        }
        if (((A_TickCount - okStart) // 1000) >= 20) {
            LogWarn("CollectionShare: neither ConfirmShare2 nor ShareSwipe detected")
            SetConfiguredGameSpeed()
            return false
        }
        Sleep, 300
    }

    adbSwipe("270 750 270 250 300")
    SetConfiguredGameSpeed()

    if (!CollectionShare_WaitScreenNeedle("Share", 34, 347, 63, 373, 20)) {
        LogWarn("CollectionShare: did not return to Share screen after swipe")
        return false
    }
    return true
}

;-------------------------------------------------------------------------------
; CollectionShare_CheckAndRun - End-of-run hook for numbered instances
;-------------------------------------------------------------------------------
CollectionShare_CheckAndRun() {
    global session, botConfig

    if (botConfig.get("deleteMethod") != "Inject Wonderpick 96P+")
        return
    if (!session.get("injectMethod") || !session.get("loadedAccount"))
        return
    deviceAccount := session.get("deviceAccount")
    if (deviceAccount = "")
        return

    day := ShareTaskDay()
    ShareTaskReleaseStale(day)
    taskFiles := ShareTaskPendingFiles(day)
    if (taskFiles.Length() = 0)
        return

    flagPath := ShareTaskDir() . "\" . day . "_donor-attempt_" . deviceAccount . ".txt"
    if (FileExist(flagPath))
        return

    for _, taskPath in taskFiles {
        task := ShareTaskRead(taskPath)
        if (task.cardId = "" || task.friendCode = "")
            continue
        if (!ShareAccountOwnsCard(deviceAccount, task.cardId))
            continue

        ; Claim before friending so only one account adds and favourites the Main
        claimedPath := ShareTaskClaim(taskPath)
        if (claimedPath = "") {
            LogInfo("CollectionShare: share task already claimed by another instance")
            continue
        }
        LogInfo("CollectionShare: account " . deviceAccount . " owns target " . task.cardId . ", claimed share task for " . task.mainInstance)

        if (!CollectionShare_FavouriteMain(task.friendCode)) {
            ShareTaskRelease(claimedPath)
            LogWarn("CollectionShare: could not friend/favourite Main " . task.mainInstance . ", claim released")
            continue
        }

        ; Friending can take minutes: restart the stale-claim clock for the share
        FileSetTime, , % claimedPath
        FormatTime, attemptTime, , yyyy-MM-dd HH:mm:ss
        FileAppend, % "Share attempt for " . task.mainInstance . " (" . task.cardId . ") at " . attemptTime . "`n", %flagPath%

        shareResult := CollectionShare_PerformShare(task.sortMode, task.expansion, task.cardId)
        if (shareResult = "lost") {
            ShareTaskSetState(claimedPath, "already-received")
            LogWarn("CollectionShare: day lost (Main already shared), task closed for " . task.cardId)
            return
        }
        if (shareResult) {
            ShareMarkCardShared(deviceAccount, task.cardId)
            ShareMarkPendingShare(task.collection, task.cardId)
            ShareTaskSetState(claimedPath, "shared")
            LogInfo("CollectionShare: shared " . task.cardId . " to " . task.mainInstance)
            return
        }

        if (!ShareTaskRelease(claimedPath))
            LogWarn("CollectionShare: could not release claim " . claimedPath)
        LogWarn("CollectionShare: share failed, claim released for next account")
        CollectionShare_BackToSocial()
        return
    }
}

; CollectionShare_CoordinateDaily lives in CollectionShareCoordinator.ahk
; (Main.ahk only: it needs HistoryImport.ahk which 1.ahk does not include).
