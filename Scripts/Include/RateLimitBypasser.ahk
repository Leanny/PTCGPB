; Rate Limit Bypasser — group reroll friend-add waves (10 ops / 300s per account)
; State lives in Scripts/<instance>.ini under [RateLimitBypasser] / [RLB_AccountN]

RLB_WINDOW_MS := 300000
RLB_MAX_OPS := 10

RLB_IsEligible() {
    global botConfig
    if (!botConfig.get("groupRerollEnabled"))
        return false
    if (botConfig.get("deleteMethod") != "Inject Wonderpick 96P+")
        return false
    ids := RLB_LoadIdsFromFile()
    n := IsObject(ids) ? ids.MaxIndex() : 0
    if (n = "")
        n := 0
    return (n >= 11)
}

RLB_LoadIdsFromFile() {
    friendIDs := ReadFile("ids")
    if (!friendIDs)
        friendIDs := []
    return friendIDs
}

RLB_IniPath() {
    global session
    return session.get("scriptIniFile")
}

RLB_GetMaxCache() {
    global botConfig
    v := botConfig.get("rateLimitBypasserMaxCache")
    if (v = "" || v = "ERROR")
        return 0
    v := v + 0
    if (v < 0)
        v := 0
    return v
}

RLB_IsActive() {
    IniRead, active, % RLB_IniPath(), RateLimitBypasser, Active, 0
    return (active = 1)
}

RLB_ClearWave() {
    ini := RLB_IniPath()
    IniRead, count, %ini%, RateLimitBypasser, AccountCount, 0
    count := count + 0
    Loop, % count {
        IniDelete, %ini%, % "RLB_Account" . A_Index
    }
    IniDelete, %ini%, RateLimitBypasser
}

RLB_EnsureWave() {
    global botConfig, session

    if (RLB_IsActive()) {
        RLB_LoadFrozenIdsIntoSession()
        return true
    }

    ids := RLB_LoadIdsFromFile()
    if (botConfig.get("FriendID") != "" && !HasVal(ids, botConfig.get("FriendID")))
        ids.Push(botConfig.get("FriendID"))

    n := ids.MaxIndex()
    if (n = "" || n < 11)
        return false

    ; One shuffle at freeze; shared order for all accounts
    Loop % n {
        i := n - A_Index + 1
        Random, j, 1, %i%
        temp := ids[i] . ""
        ids[i] := ids[j] . ""
        ids[j] := temp . ""
    }

    frozen := ""
    Loop, % n {
        if (A_Index > 1)
            frozen .= "|"
        frozen .= ids[A_Index]
    }

    ini := RLB_IniPath()
    IniWrite, 1, %ini%, RateLimitBypasser, Active
    IniWrite, %frozen%, %ini%, RateLimitBypasser, IdsFrozen
    IniWrite, %n%, %ini%, RateLimitBypasser, IdsCount
    IniWrite, 0, %ini%, RateLimitBypasser, StopDrain
    IniWrite, %A_NowUTC%, %ini%, RateLimitBypasser, StartedAt
    IniWrite, % RLB_GetMaxCache(), %ini%, RateLimitBypasser, MaxCache
    IniWrite, 0, %ini%, RateLimitBypasser, AccountCount

    session.set("friendIDs", ids)
    session.set("packMethod", 0)
    ; Stop-at-end is the supported stop mode; do not arm stopToggle until the user stops.

    LogInfo("RLB wave started | ids=" . n . " | maxCache=" . RLB_GetMaxCache(), "GroupReroll.txt")
    return true
}

RLB_LoadFrozenIdsIntoSession() {
    global session
    IniRead, frozen, % RLB_IniPath(), RateLimitBypasser, IdsFrozen,
    ids := []
    if (frozen != "" && frozen != "ERROR") {
        Loop, Parse, frozen, |
        {
            if (A_LoopField != "")
                ids.Push(A_LoopField . "")
        }
    }
    session.set("friendIDs", ids)
    session.set("packMethod", 0)
}

RLB_AccountCount() {
    IniRead, count, % RLB_IniPath(), RateLimitBypasser, AccountCount, 0
    return count + 0
}

RLB_Section(idx) {
    return "RLB_Account" . idx
}

RLB_ReadAccount(idx) {
    ini := RLB_IniPath()
    sec := RLB_Section(idx)
    acc := {}
    IniRead, v, %ini%, %sec%, FileName,
    acc["fileName"] := (v = "ERROR") ? "" : v
    IniRead, v, %ini%, %sec%, DeviceAccount,
    acc["deviceAccount"] := (v = "ERROR") ? "" : v
    IniRead, v, %ini%, %sec%, NextIndex, 1
    acc["nextIndex"] := v + 0
    if (acc["nextIndex"] < 1)
        acc["nextIndex"] := 1
    IniRead, v, %ini%, %sec%, WindowStart, 0
    acc["windowStart"] := v + 0
    IniRead, v, %ini%, %sec%, OpsInWindow, 0
    acc["opsInWindow"] := v + 0
    IniRead, v, %ini%, %sec%, Phase, adding
    acc["phase"] := (v = "ERROR" || v = "") ? "adding" : v
    IniRead, v, %ini%, %sec%, Friended, 0
    acc["friended"] := v + 0
    IniRead, v, %ini%, %sec%, LoadDir,
    acc["loadDir"] := (v = "ERROR") ? "" : v
    IniRead, v, %ini%, %sec%, BatchId, 0
    acc["batchId"] := v + 0
    IniRead, v, %ini%, %sec%, CockpitCounted, 0
    acc["cockpitCounted"] := v + 0
    return acc
}

RLB_WriteAccount(idx, acc) {
    ini := RLB_IniPath()
    sec := RLB_Section(idx)
    IniWrite, % acc["fileName"], %ini%, %sec%, FileName
    IniWrite, % acc["deviceAccount"], %ini%, %sec%, DeviceAccount
    IniWrite, % acc["nextIndex"], %ini%, %sec%, NextIndex
    IniWrite, % acc["windowStart"], %ini%, %sec%, WindowStart
    IniWrite, % acc["opsInWindow"], %ini%, %sec%, OpsInWindow
    IniWrite, % acc["phase"], %ini%, %sec%, Phase
    IniWrite, % acc["friended"], %ini%, %sec%, Friended
    if (acc.HasKey("loadDir"))
        IniWrite, % acc["loadDir"], %ini%, %sec%, LoadDir
    if (acc.HasKey("batchId"))
        IniWrite, % acc["batchId"], %ini%, %sec%, BatchId
    if (acc.HasKey("cockpitCounted"))
        IniWrite, % acc["cockpitCounted"], %ini%, %sec%, CockpitCounted
}

RLB_FindAccountIdxByFile(fileName) {
    count := RLB_AccountCount()
    Loop, % count {
        acc := RLB_ReadAccount(A_Index)
        if (acc["fileName"] = fileName)
            return A_Index
    }
    return 0
}

RLB_IdsCount() {
    IniRead, n, % RLB_IniPath(), RateLimitBypasser, IdsCount, 0
    return n + 0
}

RLB_NowEpoch() {
    now := A_NowUTC
    EnvSub, now, 1970, seconds
    return now
}

RLB_WindowRemainingMs(acc) {
    global RLB_WINDOW_MS, RLB_MAX_OPS
    if (acc["opsInWindow"] < RLB_MAX_OPS)
        return 0
    if (acc["windowStart"] <= 0)
        return 0
    elapsedMs := (RLB_NowEpoch() - acc["windowStart"]) * 1000
    if (elapsedMs >= RLB_WINDOW_MS)
        return 0
    return RLB_WINDOW_MS - elapsedMs
}

RLB_RefreshWindowIfExpired(ByRef acc) {
    global RLB_WINDOW_MS, RLB_MAX_OPS
    if (acc["opsInWindow"] < RLB_MAX_OPS)
        return
    if (acc["windowStart"] <= 0) {
        acc["opsInWindow"] := 0
        return
    }
    elapsedMs := (RLB_NowEpoch() - acc["windowStart"]) * 1000
    if (elapsedMs >= RLB_WINDOW_MS) {
        acc["opsInWindow"] := 0
        acc["windowStart"] := 0
    }
}

RLB_CanStartTranche(acc) {
    global RLB_MAX_OPS
    if (acc["phase"] != "adding")
        return false
    n := RLB_IdsCount()
    if (acc["nextIndex"] > n)
        return false
    RLB_RefreshWindowIfExpired(acc)
    return (acc["opsInWindow"] < RLB_MAX_OPS)
}

RLB_CountAdding() {
    count := RLB_AccountCount()
    c := 0
    Loop, % count {
        acc := RLB_ReadAccount(A_Index)
        if (acc["phase"] = "adding" || acc["phase"] = "readyForPacks")
            c++
    }
    return c
}

RLB_IsStopDrain() {
    global session
    IniRead, drain, % RLB_IniPath(), RateLimitBypasser, StopDrain, 0
    if (drain = 1)
        return true
    return (session.get("stopToggle") ? true : false)
}

RLB_SetStopDrain(val := 1) {
    IniWrite, %val%, % RLB_IniPath(), RateLimitBypasser, StopDrain
}

; Returns action object via session keys:
; rlbAction = resume|fresh|wait|exit|none
; rlbResumeIdx, rlbWaitMs
RLB_PickNextAction() {
    global session, RLB_MAX_OPS

    session.set("rlbAction", "none")
    session.set("rlbResumeIdx", 0)
    session.set("rlbWaitMs", 0)

    if (!RLB_IsActive())
        return

    n := RLB_IdsCount()
    count := RLB_AccountCount()
    stopDrain := RLB_IsStopDrain()
    maxCache := RLB_GetMaxCache()
    IniRead, snapMax, % RLB_IniPath(), RateLimitBypasser, MaxCache, 
    if (snapMax != "" && snapMax != "ERROR")
        maxCache := snapMax + 0

    ; Prefer readyForPacks
    Loop, % count {
        acc := RLB_ReadAccount(A_Index)
        if (acc["phase"] = "readyForPacks") {
            session.set("rlbAction", "resume")
            session.set("rlbResumeIdx", A_Index)
            return
        }
    }

    ; Prefer cached account ready for another add tranche
    nearestWait := 0
    Loop, % count {
        acc := RLB_ReadAccount(A_Index)
        if (acc["phase"] != "adding")
            continue
        if (acc["nextIndex"] > n)
            continue
        RLB_RefreshWindowIfExpired(acc)
        RLB_WriteAccount(A_Index, acc)
        if (RLB_CanStartTranche(acc)) {
            session.set("rlbAction", "resume")
            session.set("rlbResumeIdx", A_Index)
            return
        }
        rem := RLB_WindowRemainingMs(acc)
        if (rem > 0 && (nearestWait = 0 || rem < nearestWait))
            nearestWait := rem
    }

    addingCount := RLB_CountAdding()
    underCap := (maxCache <= 0 || addingCount < maxCache)

    if (!stopDrain && underCap) {
        session.set("rlbAction", "fresh")
        return
    }

    if (nearestWait > 0) {
        session.set("rlbAction", "wait")
        session.set("rlbWaitMs", nearestWait)
        return
    }

    ; Nothing left in cache
    if (stopDrain || count = 0) {
        ; Still have incomplete?
        hasWork := false
        Loop, % count {
            acc := RLB_ReadAccount(A_Index)
            if (acc["phase"] = "adding" || acc["phase"] = "readyForPacks") {
                hasWork := true
                break
            }
        }
        if (!hasWork) {
            session.set("rlbAction", "exit")
            return
        }
    }

    session.set("rlbAction", "wait")
    session.set("rlbWaitMs", 5000)
}

RLB_WaitCooldown(waitMs) {
    global session
    if (waitMs < 1000)
        waitMs := 1000
    endTick := A_TickCount + waitMs
    LogInfo("RLB waiting cooldown | ms=" . waitMs, "GroupReroll.txt")
    while (A_TickCount < endTick) {
        left := Ceil((endTick - A_TickCount) / 1000)
        CreateStatusMessage("Rate Limit Bypasser`nCooldown " . left . "s",,,, false)
        writeLastActivityEpoch(session.get("scriptName"), 0)
        Sleep, 2000
        if (session.get("stopToggle"))
            RLB_SetStopDrain(1)
    }
}

RLB_RegisterCurrentAccount() {
    global session

    fileName := session.get("accountFileName")
    if (fileName = "")
        return 0

    existing := RLB_FindAccountIdxByFile(fileName)
    if (existing > 0)
        return existing

    idx := RLB_AccountCount() + 1
    IniWrite, %idx%, % RLB_IniPath(), RateLimitBypasser, AccountCount

    batchId := RLB_AssignBatchIdForNewAccount()

    acc := {}
    acc["fileName"] := fileName
    acc["deviceAccount"] := session.get("deviceAccount")
    acc["nextIndex"] := 1
    acc["windowStart"] := 0
    acc["opsInWindow"] := 0
    acc["phase"] := "adding"
    acc["friended"] := 0
    acc["loadDir"] := session.get("loadDir")
    acc["batchId"] := batchId
    acc["cockpitCounted"] := 0
    RLB_WriteAccount(idx, acc)

    LogInfo("RLB registered account | idx=" . idx . " | file=" . fileName . " | batch=" . batchId, "GroupReroll.txt")
    return idx
}

; Join an open batch (still has adding/readyForPacks); otherwise open a new batch.
RLB_AssignBatchIdForNewAccount() {
    ini := RLB_IniPath()
    IniRead, openBatch, %ini%, RateLimitBypasser, OpenBatchId, 0
    openBatch := openBatch + 0
    count := RLB_AccountCount()
    Loop, % count {
        acc := RLB_ReadAccount(A_Index)
        if ((acc["phase"] = "adding" || acc["phase"] = "readyForPacks") && acc["batchId"] > 0) {
            if (openBatch < 1)
                openBatch := acc["batchId"]
            IniWrite, %openBatch%, %ini%, RateLimitBypasser, OpenBatchId
            return openBatch
        }
    }
    openBatch := openBatch + 1
    if (openBatch < 1)
        openBatch := 1
    IniWrite, %openBatch%, %ini%, RateLimitBypasser, OpenBatchId
    return openBatch
}

RLB_OnSendAttempt(accIdx) {
    global session, RLB_MAX_OPS

    if (accIdx < 1)
        return
    acc := RLB_ReadAccount(accIdx)
    RLB_RefreshWindowIfExpired(acc)
    if (acc["opsInWindow"] < 1 || acc["windowStart"] <= 0)
        acc["windowStart"] := RLB_NowEpoch()
    acc["opsInWindow"] := acc["opsInWindow"] + 1
    acc["friended"] := 1
    RLB_WriteAccount(accIdx, acc)
    writeLastActivityEpoch(session.get("scriptName"), 0)
}

RLB_AfterTranche(accIdx, nextIdx, rateLimited) {
    global session, RLB_MAX_OPS

    acc := RLB_ReadAccount(accIdx)
    acc["nextIndex"] := nextIdx
    if (rateLimited && acc["opsInWindow"] < RLB_MAX_OPS) {
        ; Premature rate limit: treat window as full
        if (acc["windowStart"] <= 0)
            acc["windowStart"] := RLB_NowEpoch()
        acc["opsInWindow"] := RLB_MAX_OPS
    }
    n := RLB_IdsCount()
    if (nextIdx > n)
        acc["phase"] := "readyForPacks"
    else
        acc["phase"] := "adding"
    if (session.get("friended"))
        acc["friended"] := 1
    RLB_WriteAccount(accIdx, acc)

    LogInfo("RLB tranche done | idx=" . accIdx . " | next=" . nextIdx . "/" . n . " | ops=" . acc["opsInWindow"] . " | rateLimited=" . rateLimited . " | phase=" . acc["phase"], "GroupReroll.txt")
}

RLB_MarkAccountDone(accIdx) {
    acc := RLB_ReadAccount(accIdx)
    acc["phase"] := "done"
    RLB_WriteAccount(accIdx, acc)
    RLB_FlushCockpitIfBatchComplete(acc["batchId"])
}

; Cockpit: count N runs only when the last account of a batch finishes RemoveFriends
; (not after each add-tranche of 10).
RLB_FlushCockpitIfBatchComplete(batchId) {
    global session

    batchId := batchId + 0
    if (batchId < 1)
        return

    count := RLB_AccountCount()
    pending := 0
    Loop, % count {
        acc := RLB_ReadAccount(A_Index)
        if (acc["batchId"] != batchId)
            continue
        if (acc["phase"] = "adding" || acc["phase"] = "readyForPacks")
            return ; batch still in progress
        if (acc["phase"] = "done" && !acc["cockpitCounted"])
            pending++
    }
    if (pending < 1)
        return

    RLB_CreditCockpitRuns(pending)

    Loop, % count {
        acc := RLB_ReadAccount(A_Index)
        if (acc["batchId"] = batchId && acc["phase"] = "done") {
            acc["cockpitCounted"] := 1
            RLB_WriteAccount(A_Index, acc)
        }
    }
    LogInfo("RLB cockpit credited | batch=" . batchId . " | runs=" . pending, "GroupReroll.txt")
}

; Emit N distinct start/end epoch pairs so Cockpit aggregator counts N runs.
RLB_CreditCockpitRuns(n) {
    global session

    n := n + 0
    if (n < 1)
        return

    base := RLB_NowEpoch()
    ini := session.get("scriptIniFile")
    Loop, % n {
        startEp := base + (A_Index - 1) * 2
        endEp := startEp + 1
        IniWrite, %startEp%, %ini%, Metrics, LastStartEpoch
        IniWrite, %endEp%, %ini%, Metrics, LastEndEpoch
    }
    now := A_NowUTC
    IniWrite, %now%, %ini%, Metrics, LastEndTimeUTC
    session.set("rerolls", session.get("rerolls") + n)
    session.set("rerolls_local", session.get("rerolls_local") + n)
    IniWrite, % session.get("rerolls"), %ini%, Metrics, rerolls
    clearLastActivityEpoch(session.get("scriptName"))
}

RLB_MarkCockpitTrancheComplete() {
    ; Deprecated: cockpit runs are credited in RLB_FlushCockpitIfBatchComplete.
}

RLB_RemoveFromQueueOnly() {
    ; Like MarkAccountAsClaimed: drop from list_current without 24h used lock
    global session

    if (!session.get("accountFileName"))
        return

    saveDir := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName")
    outputTxt := saveDir . "\list_current.txt"
    if (!FileExist(outputTxt))
        return

    FileRead, fileContent, %outputTxt%
    fileLines := StrSplit(fileContent, "`n", "`r")
    newListContent := ""
    Loop, % fileLines.MaxIndex() {
        if (fileLines[A_Index] = session.get("accountFileName"))
            continue
        if (StrLen(fileLines[A_Index]) >= 5)
            newListContent .= fileLines[A_Index] "`r`n"
    }
    FileDelete, %outputTxt%
    FileAppend, %newListContent%, %outputTxt%
}

RLB_ParkCurrentAccount(accIdx) {
    global session

    PersistLoadedAccountForRecovery(session.get("loadedAccount"))
    RLB_RemoveFromQueueOnly()
    session.set("loadedAccount", false)
    session.set("rlbParkedIdx", accIdx)
    LogInfo("RLB parked account | idx=" . accIdx . " | file=" . session.get("accountFileName"), "GroupReroll.txt")
}

RLB_FinishWaveIfDone() {
    count := RLB_AccountCount()
    if (count < 1)
        return false
    Loop, % count {
        acc := RLB_ReadAccount(A_Index)
        if (acc["phase"] != "done")
            return false
    }
    RLB_ClearWave()
    LogInfo("RLB wave cleared (all done)", "GroupReroll.txt")
    return true
}

; Inject a specific account XML by filename (for cache resume)
loadAccountByFileName(fileName) {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig, session

    session.get("missionDoneList")["beginnerMissionsDone"] := 0
    session.get("missionDoneList")["specialMissionsDone"] := 0
    session.get("missionDoneList")["accountHasPackInTesting"] := 0
    session.get("missionDoneList")["receivedGiftDone"] := 0

    if (session.get("stopToggle"))
        RLB_SetStopDrain(1)

    saveDir := A_ScriptDir "\..\Accounts\Saved\" . session.get("scriptName")
    session.set("loadDir", saveDir)
    loadFile := saveDir . "\" . fileName
    if (!FileExist(loadFile)) {
        LogWarn("RLB resume missing file | " . loadFile, "GroupReroll.txt")
        return false
    }

    session.set("accountFileName", fileName)
    session.set("accountOpenPacks", 0)
    session.set("accountFileNameOrig", "")
    session.set("accountHasPackInfo", 0)
    session.set("currentLoadedAccountIndex", 1)
    session.set("language", "")
    session.set("accountFriendInfoChecked", "")

    CreateStatusMessage("RLB resuming: " . fileName,,,, false, true)
    closePTCGPApp()
    Sleep, 50
    clearMissionCache()
    Sleep, 100

    RunWait, % session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort") . " push " . loadFile . " /sdcard/deviceAccount.xml",, Hide
    adbWriteRaw("cp /sdcard/deviceAccount.xml /data/data/jp.pokemon.pokemontcgp/shared_prefs/deviceAccount:.xml")
    adbWriteRaw("rm -f /sdcard/deviceAccount.xml")
    Sleep, 100

    loadedAccountMeta := AccountMetadata_Get(session.get("scriptName"), fileName, loadFile)
    if (loadedAccountMeta["packCount"] != "") {
        session.set("accountOpenPacks", loadedAccountMeta["packCount"] + 0)
        session.set("accountHasPackInfo", 1)
    }

    session.set("deviceAccount", GetDeviceAccountFromXML())
    startPTCGPApp_ApplyMetadataLanguage(loadFile)
    startPTCGPApp()
    CreateStatusMessage("Account: " . fileName . "`nDeviceAccount: " . session.get("deviceAccount"), "AccountInfo", 0, 46, false)
    SetTimer, DestoryAccountInfoUI, -15000
    getMetaData()

    try {
        cockpitIni := A_ScriptDir . "\" . session.get("scriptName") . ".ini"
        IniWrite, %fileName%, %cockpitIni%, Metrics, currentAccount
    } catch e {
    }

    PersistLoadedAccountForRecovery(loadFile)
    return loadFile
}

RLB_WaitForFriendAccepts() {
    global botConfig, session
    Loop % botConfig.get("waitTime") {
        CreateStatusMessage("Waiting for friends to accept request`n(" . A_Index . "/" . botConfig.get("waitTime") . " seconds)")
        Sleep, 1000
        writeLastActivityEpoch(session.get("scriptName"), 4000)
    }
}
