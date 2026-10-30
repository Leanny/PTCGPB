; Pack result reading, card evaluation and god pack handling

InitPackOpening(full := false) {
    prof := Prof_Scope(A_ThisFunc)

    if (!EnsurePTCGPBHelperInstalled())
        return false
    adbWriteRaw("rm -f /data/ptcgp/result.rc")
    adbWriteRaw("rm -f /data/ptcgp/result.log")
    adbWriteRaw("pkill -f /data/ptcgp/ptcgpb")

    SavePackOpeningMissionUserPrefsSnapshot("pre")
    StartPtcgpbWatchCards(full)
}

PackOpeningMissionUserPrefsPath() {
    return "/data/data/jp.pokemon.pokemontcgp/files/UserPreferences/v1/MissionUserPrefs"
}

PackOpeningMissionUserPrefsSnapshotPath(kind) {
    global session
    return "/data/ptcgp/" . session.get("scriptName") . "_" . kind
}

SavePackOpeningMissionUserPrefsSnapshot(kind) {
    sourcePath := PackOpeningMissionUserPrefsPath()
    snapshotPath := PackOpeningMissionUserPrefsSnapshotPath(kind)

    adbWriteRaw("mkdir -p /data/ptcgp")
    adbWriteRaw("rm -f " . snapshotPath)
    adbWriteRaw("if [ -f " . sourcePath . " ]; then cp -f " . sourcePath . " " . snapshotPath . "; fi")
}

PullPackOpeningMissionUserPrefsSnapshot(kind, failedDir, uniquePrefix) {
    global session

    if !FileExist(failedDir)
        FileCreateDir, %failedDir%

    remotePath := PackOpeningMissionUserPrefsSnapshotPath(kind)
    sdcardPath := "/sdcard/" . uniquePrefix . "_" . kind . "_MissionUserPrefs"
    localPath := failedDir . "\" . uniquePrefix . "_" . kind

    if (FileExist(localPath))
        FileDelete, %localPath%

    adbWriteRaw("rm -f " . sdcardPath)
    adbWriteRaw("if [ -f " . remotePath . " ]; then cp -f " . remotePath . " " . sdcardPath . " && chmod 666 " . sdcardPath . "; fi")
    RunWait, % """" . session.get("adbPath") . """ -s 127.0.0.1:" . session.get("adbPort") . " pull """ . sdcardPath . """ """ . localPath . """",, Hide
    adbWriteRaw("rm -f " . sdcardPath)

    exists := FileExist(localPath) ? true : false
    return { kind: kind, remotePath: remotePath, localPath: localPath, exists: exists }
}

PullPackOpeningResultLog(failedDir, uniquePrefix) {
    global session

    debugLogFile := "debug_cards.txt"
    if !FileExist(failedDir)
        FileCreateDir, %failedDir%

    remotePath := "/data/ptcgp/result.log"
    sdcardPath := "/sdcard/" . uniquePrefix . "_result.log"
    localPath := failedDir . "\" . uniquePrefix . "_result.log"

    remoteStatus := Trim(StrReplace(adbWriteRaw("if [ -f " . remotePath . " ]; then echo present:$(wc -c < " . remotePath . "); else echo missing; fi", true), "`r"), "`n`t ")
    LogWarn("PullPackOpeningResultLog begin | remote=" . remotePath . " | remoteStatus=" . remoteStatus . " | staging=" . sdcardPath . " | local=" . localPath, debugLogFile)

    localDeleteStatus := "not-needed"
    if (FileExist(localPath)) {
        FileDelete, %localPath%
        localDeleteStatus := ErrorLevel ? "failed" : "ok"
    }

    stagingCleanupStatus := Trim(StrReplace(adbWriteRaw("if rm -f " . sdcardPath . "; then echo ok; else echo failed; fi", true), "`r"), "`n`t ")
    stagingCopyStatus := Trim(StrReplace(adbWriteRaw("if [ ! -f " . remotePath . " ]; then echo remote-missing; elif cp -f " . remotePath . " " . sdcardPath . " && chmod 666 " . sdcardPath . "; then echo ok; else echo failed; fi", true), "`r"), "`n`t ")
    RunWait, % """" . session.get("adbPath") . """ -s 127.0.0.1:" . session.get("adbPort") . " pull """ . sdcardPath . """ """ . localPath . """",, Hide
    pullExitCode := ErrorLevel
    finalCleanupStatus := Trim(StrReplace(adbWriteRaw("if rm -f " . sdcardPath . "; then echo ok; else echo failed; fi", true), "`r"), "`n`t ")

    exists := FileExist(localPath) ? true : false
    localSize := 0
    resultLogContent := "(local result.log is missing)"
    readSucceeded := false
    if (exists) {
        FileGetSize, localSize, %localPath%
        FileRead, resultLogContent, %localPath%
        readError := ErrorLevel
        readSucceeded := !readError
        if (!readSucceeded)
            resultLogContent := "(failed to read local result.log; ErrorLevel=" . readError . ")"
        else if (resultLogContent = "")
            resultLogContent := "(empty)"
    }

    LogWarn("PullPackOpeningResultLog transfer | localDelete=" . localDeleteStatus . " | initialCleanup=" . stagingCleanupStatus . " | stagingCopy=" . stagingCopyStatus . " | adbPullExitCode=" . pullExitCode . " | finalCleanup=" . finalCleanupStatus . " | localExists=" . (exists ? "yes" : "no") . " | localBytes=" . localSize . " | read=" . (readSucceeded ? "ok" : "unavailable"), debugLogFile)
    LogWarn("PullPackOpeningResultLog contents begin`n" . resultLogContent . "`nPullPackOpeningResultLog contents end", debugLogFile)

    return { kind: "result.log", remotePath: remotePath, localPath: localPath, exists: exists, remoteStatus: remoteStatus, pullExitCode: pullExitCode, localSize: localSize, readSucceeded: readSucceeded }
}

ReportPackRecognitionFailure(reason := "Card Recognition Failed, use fallback mechanism") {
    global session, botConfig

    LogWarn("Card recognition failed | pack=" . session.get("openPack") . " | reason=" . reason)
    root := getScriptBaseFolder()
    failedDir := root . "\Logs\failed"
    uniquePrefix := A_Now . "_" . session.get("scriptName") . "_pack" . session.get("packsInPool")

    preSnapshot := PullPackOpeningMissionUserPrefsSnapshot("pre", failedDir, uniquePrefix)
    postSnapshot := PullPackOpeningMissionUserPrefsSnapshot("post", failedDir, uniquePrefix)
    resultLog := PullPackOpeningResultLog(failedDir, uniquePrefix)

    message := reason . "\nPlease submit these files for the bug report as well."
    for _, snapshot in [preSnapshot, postSnapshot] {
        localPathForMessage := StrReplace(snapshot.localPath, "\", "/")
        if (snapshot.exists) {
            message .= "\n" . snapshot.kind . ": " . localPathForMessage
            LogWarn("Card recognition failure " . snapshot.kind . " MissionUserPrefs saved: " . snapshot.localPath, "debug_cards.txt")
        } else {
            message .= "\n" . snapshot.kind . ": missing (remote " . snapshot.remotePath . " was not available)"
            LogWarn("Card recognition failure " . snapshot.kind . " MissionUserPrefs missing: " . snapshot.remotePath, "debug_cards.txt")
        }
    }

    resultLogPathForMessage := StrReplace(resultLog.localPath, "\", "/")
    if (resultLog.exists) {
        message .= "\n" . resultLog.kind . ": " . resultLogPathForMessage
        LogWarn("Card recognition failure result.log saved: " . resultLog.localPath, "debug_cards.txt")
    } else {
        message .= "\n" . resultLog.kind . ": missing (remote " . resultLog.remotePath . " was not available)"
        LogWarn("Card recognition failure result.log missing: " . resultLog.remotePath, "debug_cards.txt")
    }

    ownerWebhookURL := botConfig.get("heartBeatOwnerWebHookURL")
    if (ownerWebhookURL != "")
        LogToDiscord(message,, false,,, ownerWebhookURL)
    else
        LogWarn("Owner Discord webhook URL is not configured. Card recognition failure message was not sent.", "Discord.txt")
}

GetStdout(cmd) {
    prof := Prof_Scope(A_ThisFunc)
    shell := ComObjCreate("WScript.Shell")
    exec := shell.Exec(cmd)
    return exec.StdOut.ReadAll()
}

TerminateHelper() {
    adbWriteRaw("pkill -f /data/ptcgp/ptcgpb")
}

ParsePackResultOutput(output) {
    output := StrReplace(output, "`r")
    output := Trim(output, "`n ")
    lines := StrSplit(output, "`n")
    parsedLines := []
    for _, line in lines {
        line := Trim(line)
        if (line != "")
            parsedLines.Push(line)
    }
    lines := parsedLines

    if (lines.Length() < 4)
        return false

    pulls := []
    cards := []
    rarity := []
    packNames := []
    shinedust := 0
    raw_msg := ""

    idx := 1
    while (idx + 2 <= lines.Length()) {
        pullCards := []
        for _, val in StrSplit(lines[idx], ",") {
            card := Trim(val)
            if (card != "")
                pullCards.Push(card)
        }

        pullPack := Trim(lines[idx + 1])

        pullRarity := []
        for _, val in StrSplit(lines[idx + 2], ",") {
            pullRarity.Push(Trim(val) + 0)
        }

        if (pullCards.Length() = 0 || pullRarity.Length() = 0)
            break

        pullShinedust := lines[idx + 3] + 0
        shinedust += pullShinedust

        pullRaw := lines[idx] . "`n" . lines[idx + 1] . "`n" . lines[idx + 2] . "`n" . lines[idx + 3]
        pulls.Push({ cards: pullCards, pack: pullPack, rarity: pullRarity, shinedust: pullShinedust, raw: pullRaw })
        packNames.Push(pullPack)

        for _, card in pullCards
            cards.Push(card)
        for _, rare in pullRarity
            rarity.Push(rare)

        if (raw_msg != "")
            raw_msg .= "`n"
        raw_msg .= pullRaw

        idx += 4
    }

    if (pulls.Length() = 0)
        return false

    pack := ""
    for _, packName in packNames {
        if (pack != "")
            pack .= ", "
        pack .= packName
    }

    return { cards: cards, pack: pack, rarity: rarity, shinedust: shinedust, raw: raw_msg, pulls: pulls }
}

; Wait for the Helper to produce a parseable result.rc containing the cards,
; then read and parse it. Does not terminate the watcher (caller must do that
; once the result has been consumed).
ReadEliteDeckResult(timeoutSec := 45) {
    prof := Prof_Scope(A_ThisFunc)
    global session

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    session.set("failSafe", A_TickCount)
    Loop {
        output := GetStdout(adbCommand . " shell cat /data/ptcgp/result.rc")
        result := ParsePackResultOutput(output)
        if (result)
            return result

        Sleep, 500
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Elite Deck result...`n(" . failSafeTime . "/" . timeoutSec . " seconds)")
        if (failSafeTime >= timeoutSec)
            break
    }
    return false
}

UpdatePackCountAfterOpening(defaultOpenedPacks := 1) {
    global session

    expectedOpenedPacks := session.get("expectedPackOpenCount") + 0
    if (expectedOpenedPacks >= 1 && expectedOpenedPacks <= 10)
        defaultOpenedPacks := expectedOpenedPacks
    session.set("expectedPackOpenCount", 1)

    oldPackCount := session.get("accountOpenPacks") + 0
    openedPackCount := defaultOpenedPacks
    newPackCount := EvaluatePackCount()

    if (newPackCount = 0) {
        session.set("accountOpenPacks", oldPackCount + defaultOpenedPacks)
    } else {
        packDelta := newPackCount - oldPackCount
        if (packDelta >= 1 && packDelta <= 10)
            openedPackCount := packDelta

        session.set("accountOpenPacks", newPackCount)

        if (session.get("injectMethod") && session.get("loadedAccount") && session.get("accountFileName") != "") {
            accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), session.get("loadedAccount"))
            accountMeta["deviceAccount"] := GetCurrentDeviceAccountForMetadata()
            accountMeta["packCount"] := newPackCount
            AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)
        }
    }

    if (session.get("injectMethod") && session.get("loadedAccount"))
        UpdateAccount()

    session.set("packsInPool", session.get("packsInPool") + openedPackCount)
    session.set("packsThisRun", session.get("packsThisRun") + openedPackCount)

    LogInfo("Pack opened | pack=" . session.get("openPack") . " | opened=" . openedPackCount . " | accountPacks=" . session.get("accountOpenPacks") . " | thisRun=" . session.get("packsThisRun"))

    return openedPackCount
}

EvaluatePack() {
    prof := Prof_Scope(A_ThisFunc)
    global session
    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    expectedOpenedPacks := session.get("expectedPackOpenCount") + 0
    maxAttempts := expectedOpenedPacks > 1 ? 100 : 10
    foundResult := false
    Loop, %maxAttempts% {
        RunWait, % adbCommand . " shell test -f /data/ptcgp/result.rc", , Hide
        if (ErrorLevel = 0) {
            foundResult := true
            break
        }
        Sleep, 300
    }
    if (foundResult && expectedOpenedPacks > 1)
        Sleep, 1000
    adbWriteRaw("pkill -f /data/ptcgp/ptcgpb")
    waitadb()

    SavePackOpeningMissionUserPrefsSnapshot("post")

    output := GetStdout(adbCommand . " shell cat /data/ptcgp/result.rc")
    parsedResult := ParsePackResultOutput(output)
    if (!parsedResult && expectedOpenedPacks > 1)
        LogDebug("EvaluatePack 10-pack parse failed. result.rc length=" . StrLen(output), "debug_cards.txt")
    return parsedResult
}

EvaluatePackCount() {
    prof := Prof_Scope(A_ThisFunc)

    LogTrace("EvaluatePackCount running ptcgpb packcount", "ADB.txt")
    return GetPtcgpbPackCount()
}

RecoverPack() {
    prof := Prof_Scope(A_ThisFunc)
    global session
    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")

    pre := PackOpeningMissionUserPrefsSnapshotPath("pre")
    post := PackOpeningMissionUserPrefsSnapshotPath("post")

    adbWriteRaw("rm -f /data/ptcgp/result.rc")
    adbWriteRaw("rm -f /data/ptcgp/result.log")
    adbWriteRaw("/data/ptcgp/ptcgpb diff-files --duplicate " . pre . " " . post)
    output := GetStdout(adbCommand . " shell cat /data/ptcgp/result.rc")
    return ParsePackResultOutput(output)
}

CardDetection_QueueGodPack(validity, cards := "", finalizeAccount := false) {
    global session

    session.set("keepAccount", true)
    session.set("foundGP", true)
    session.set("pendingGodPack", true)
    session.set("pendingGodPackValidity", validity)
    session.set("pendingGodPackCards", cards)
    session.set("pendingGodPackFinalize", finalizeAccount)
    session.set("manualVipValidity", validity)
    session.set("pendingGodPackScreenshot", Screenshot(validity))
    LogInfo("Queued " . validity . " God Pack notification until pack cleanup finishes", "GPlog.txt")
    return true
}

CardDetection_HasPendingGodPack() {
    global session
    return session.get("pendingGodPack")
}

CardDetection_CheckGodPackDeferred(invalidPack := false, cards := "", finalizeAccount := false) {
    global botConfig, session

    currentPackInfo := session.get("currentPackInfo")

    normalBorders := currentPackInfo["TypeCount"]["normal"]
    if (normalBorders) {
        logMessage := "Instance: " . session.get("scriptName") " | Not a GP"
        LogDebug(logMessage, "debug_cards.txt")
        CreateStatusMessage("Not a God Pack...",,,, false)
        return false
    }

    session.set("keepAccount", true)

    ; A god pack always consists of all its cards: 5 in standard packs, 4 in
    ; Deluxe/DeluxePackMega packs. A different count means it cannot be verified.
    if (IsObject(cards)) {
        expectedCardCount := DetectFourCardPack() ? 4 : 5
        if (cards.Length() != expectedCardCount) {
            LogDebug("Instance: " . session.get("scriptName") . " | card count check failed (recognized=" . cards.Length() . ", expected=" . expectedCardCount . ")", "debug_cards.txt")
            CreateStatusMessage("Card count check failed...",,,, false)
            invalidPack := true
        }
    } else {
        totalCardsInPack := currentPackInfo["totalCardsInPack"]
        classifiedCards := 0
        For rarityName, rarityCount in currentPackInfo["TypeCount"]
            classifiedCards += rarityCount
        if (totalCardsInPack != "" && (classifiedCards != totalCardsInPack || (totalCardsInPack != 4 && totalCardsInPack != 5))) {
            LogDebug("Instance: " . session.get("scriptName") . " | card count check failed (classified=" . classifiedCards . ", expected=" . totalCardsInPack . ")", "debug_cards.txt")
            CreateStatusMessage("Card count check failed...",,,, false)
            invalidPack := true
        }
    }

    if (!invalidPack) {
        tempStarCount := currentPackInfo["TypeCount"]["fullart"] + currentPackInfo["TypeCount"]["rainbow"] + currentPackInfo["TypeCount"]["trainer"]

        logMessage := "Instance: " . session.get("scriptName") " | tempStarCount " . tempStarCount
        LogDebug(logMessage, "debug_cards.txt")

        requiredStars := botConfig.get("minStars")
        if (requiredStars > 0 && tempStarCount < requiredStars) {
            CreateStatusMessage("Pack doesn't contain enough 2 stars...",,,, false)
            invalidPack := true
        }
    }

    return CardDetection_QueueGodPack(invalidPack ? "Invalid" : "Valid", cards, finalizeAccount)
}

CardDetection_FlushPendingGodPack() {
    global session

    if (!CardDetection_HasPendingGodPack())
        return false

    validity := session.get("pendingGodPackValidity")
    cards := session.get("pendingGodPackCards")
    finalizeAccount := session.get("pendingGodPackFinalize")
    preCapturedScreenshot := session.get("pendingGodPackScreenshot")
    session.set("pendingGodPack", false)
    session.set("pendingGodPackValidity", "")
    session.set("pendingGodPackCards", "")
    session.set("pendingGodPackFinalize", false)
    session.set("pendingGodPackScreenshot", "")

    GodPackFound(validity, cards, true, preCapturedScreenshot)

    if (validity = "Invalid")
        RemoveFriends()
    IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck

    if (finalizeAccount && validity != "Invalid")
        FinalizeInjectedGodPackAccount()

    reason := (validity = "Invalid") ? "Invalid God Pack Found." : "God Pack found. Continuing..."
    restartGameInstance(reason, "GodPack")
    return true
}

CheckPack(stopEarly := false) {
    prof := Prof_Scope(A_ThisFunc)
    expectedOpenedPacks := session.get("expectedPackOpenCount") + 0

    result := EvaluatePack()
    if (!result) {
        LogWarn("Failed at 1", "debug_cards.txt")
        RecoverPtcgpbCardRarity()
        result := RecoverPack()
    }

    if (!result) {
        LogWarn("Failed at 2", "debug_cards.txt")
        ReportPackRecognitionFailure()
        if (!stopEarly && expectedOpenedPacks > 1) {
            UpdatePackCountAfterOpening()
        }
        if (!stopEarly && expectedOpenedPacks <= 1) {
            CheckPackFallback()
        }
        return
    }
    cards := result.cards
    pack := result.pack
    rarity := result.rarity
    shinedust := result.shinedust
    raw_msg := result.raw

    ; store result as soon as the cards are known, even if rarity is incomplete
    if (cards.Length() > 0) {
        LogToCardDatabase(result)

        logMessage := "Instance: " . session.get("scriptName") " | Stored to card database"
        LogDebug(logMessage, "debug_cards.txt")

        ; Helper could not resolve some rarities, restore them from cardmaster.json
        hasMissingRarity := rarity.Length() < cards.Length()
        for _, rare in rarity {
            if (!rare)
                hasMissingRarity := true
        }


        if (hasMissingRarity) {
            RecoverPtcgpbCardRarity()
            unresolved := CardRarity_RestoreMissing(cards, rarity)
            restored := ""
            for _, r in rarity
                restored .= (restored != "" ? ", " : "") . r
            LogWarn("Restored missing rarity from cardmaster.json | unresolved=" . unresolved . " | restored=" . restored . "`n" . raw_msg, "debug_cards.txt")
            hasMissingRarity := unresolved > 0
        }
    }

    ; any rarity still unknown, fall back to manual checks
    if (cards.Length() = 0 || hasMissingRarity) {
        LogWarn(raw_msg, "debug_cards.txt")
        ; Fallback in case recognition failed
        ReportPackRecognitionFailure()
        if (!stopEarly && expectedOpenedPacks > 1) {
            UpdatePackCountAfterOpening()
        }
        if (!stopEarly && expectedOpenedPacks <= 1) {
            CheckPackFallback(cards.Length())
        }
        return
    }

    UpdatePackCountAfterOpening()
    AddShinedustToDatabase(shinedust)

    if (stopEarly) {
        if (botConfig.get("s4tEnabled")) {
            CheckCardsSimple(result)
        }
        return
    }

    ; NEW: Disable card detection for Create Bots and Inject 13P+
    ; Only run detection for Inject Wonderpick 96P+
    skipCardDetection := (botConfig.get("deleteMethod") = "Create Bots (13P)" || botConfig.get("deleteMethod") = "Inject 13P+")
    multiPullResult := (IsObject(result.pulls) && result.pulls.Length() > 1) || cards.MaxIndex() > 6

    logMessage := "Instance: " . session.get("scriptName") " | Skip Card Detection: " . skipCardDetection
    LogDebug(logMessage, "debug_cards.txt")

    ; If not doing card detection and no friends and s4t disabled, just return early
    if(skipCardDetection && !session.get("friendIDs") && botConfig.get("FriendID") = "" && !botConfig.get("s4tEnabled"))
        return false

    currentPackIs4Card := cards.MaxIndex() = 4
    currentPackIs6Card := cards.MaxIndex() = 6

    totalCardsInPack := cards.MaxIndex()

    if (!multiPullResult) {
        ; Wait for cards to render before checking.
        Loop {
            if (CheckCardLoading(totalCardsInPack) = 0)
                break
            Delay(1)
        }
        Delay(1)
    }

    found1Dmnd       := CountOccurances(cards, rarity, 1)
    found2Dmnd       := CountOccurances(cards, rarity, 2)
    found3Dmnd       := CountOccurances(cards, rarity, 3)
    found4Dmnd       := CountOccurances(cards, rarity, 4)
    found1Star       := CountOccurances(cards, rarity, 7)
    foundTrainer     := CountOccurances(cards, rarity, 5, "TR_")
    foundFullArt     := CountOccurances(cards, rarity, 5, "PK_")
    foundRainbow     := CountOccurances(cards, rarity, 8)
    foundImmersive   := CountOccurances(cards, rarity, 9)
    foundCrown       := CountOccurances(cards, rarity, 10)
    foundShiny1Star  := CountOccurances(cards, rarity, 11)
    foundShiny2Star  := CountOccurances(cards, rarity, 12)

    PackMethod_UpdateSkipFriendRenewFromCounts(foundImmersive, foundCrown, foundShiny1Star, foundShiny2Star)

    foundWishlist    := Wishlist_ProcessPack(cards, pack)
    foundWishlist2Star := Wishlist_CountTwoStarMatches(cards, rarity, session.get("wishlistMap"))

    logMessage := "Instance: " . session.get("scriptName") " | Found: " . found1Dmnd
    logMessage := logMessage . "|" . found2Dmnd
    logMessage := logMessage . "|" . found2Dmnd
    logMessage := logMessage . "|" . found3Dmnd
    logMessage := logMessage . "|" . found4Dmnd
    logMessage := logMessage . "|" . found1Star
    logMessage := logMessage . "|" . foundTrainer
    logMessage := logMessage . "|" . foundFullArt
    logMessage := logMessage . "|" . foundRainbow
    logMessage := logMessage . "|" . foundImmersive
    logMessage := logMessage . "|" . foundCrown
    logMessage := logMessage . "|" . foundShiny1Star
    logMessage := logMessage . "|" . foundShiny2Star
    LogDebug(logMessage, "debug_cards.txt")

    if (botConfig.get("s4tEnabled")) {
        tradeableList := []
        tradeableList.Push({key: "3Diamond",  flag: botConfig.get("s4t3Dmnd"),      count: found3Dmnd})
        tradeableList.Push({key: "4Diamond",  flag: botConfig.get("s4t4Dmnd"),      count: found4Dmnd})
        tradeableList.Push({key: "1Star",     flag: botConfig.get("s4t1Star"),      count: found1Star})
        tradeableList.Push({key: "Trainer",   flag: botConfig.get("s4tTrainer"),    count: foundTrainer})
        tradeableList.Push({key: "FullArt",   flag: botConfig.get("s4tFullArt"),    count: foundFullArt})
        tradeableList.Push({key: "Rainbow",   flag: botConfig.get("s4tRainbow"),    count: foundRainbow})
        tradeableList.Push({key: "Immersive", flag: botConfig.get("s4tImmersive"),  count: foundImmersive})
        tradeableList.Push({key: "Crown",     flag: botConfig.get("s4tCrown"),      count: foundCrown})
        tradeableList.Push({key: "Shiny1Star",flag: botConfig.get("s4tShiny1Star"), count: foundShiny1Star})
        tradeableList.Push({key: "Shiny2Star",flag: botConfig.get("s4tShiny2Star"), count: foundShiny2Star})
        tradeableList.Push({key: "Wishlist",  flag: botConfig.get("s4tWishlist"),   count: foundWishlist})

        foundCards := {}
        foundTradeable := 0
        for _, item in tradeableList {
            foundCards[item.key] := 0
            if (item.flag) {
                foundTradeable += item.count
                foundCards[item.key] := item.count
            }
        }

        logMessage := "Instance: " . session.get("scriptName") " | S4T Trandables: " . foundTradeable
        LogDebug(logMessage, "debug_cards.txt")

        if (foundTradeable > 0) {
            FoundTradeableNew(foundCards, pack, cards, rarity, multiPullResult)
            ; Continue with the rest of the run in s4t mode; don't return early.
        }
    }

    if (multiPullResult) {
        return false
    }

    ; Skip rest of card detection if this is Create Bots or Inject 13P+
    if (skipCardDetection) {
        return false
    }

    logMessage := "Instance: " . session.get("scriptName") " | GP Check "
    LogDebug(logMessage, "debug_cards.txt")

    foundLabel := false

    ; Check if the current pack is valid (for Inject Wonderpick 96P+ only now)
    foundShiny := foundShiny1Star + foundShiny2Star
    foundInvalid := foundShiny + foundCrown + foundImmersive
    tempStarCount := foundFullArt + foundRainbow + foundTrainer
    normalBorders := found1Dmnd + found2Dmnd + found3Dmnd + found4Dmnd

    logMessage := "Instance: " . session.get("scriptName") " | normalBorders: " . normalBorders
    LogDebug(logMessage, "debug_cards.txt")

    ; Build currentPackInfo in session so GodPackFound can read starCount correctly
    synthPackInfo := {"isVerified": true, "CardSlot": [], "TypeCount": {}}
    synthPackInfo["TypeCount"]["normal"]    := normalBorders
    synthPackInfo["TypeCount"]["1star"]     := found1Star
    synthPackInfo["TypeCount"]["3diamond"]  := found3Dmnd
    synthPackInfo["TypeCount"]["trainer"]   := foundTrainer
    synthPackInfo["TypeCount"]["fullart"]   := foundFullArt
    synthPackInfo["TypeCount"]["rainbow"]   := foundRainbow
    synthPackInfo["TypeCount"]["immersive"] := foundImmersive
    synthPackInfo["TypeCount"]["crown"]     := foundCrown
    session.set("currentPackInfo", synthPackInfo)

    if (foundInvalid && botConfig.get("InvalidCheck")) {
        logMessage := "Instance: " . session.get("scriptName") " | Invalid"
        LogDebug(logMessage, "debug_cards.txt")
        ; Skip invalid packs if invalidcheck is active
        return
    }

    if (foundInvalid) {
        logMessage := "Instance: " . session.get("scriptName") " | Doing Invalid Check"
        LogDebug(logMessage, "debug_cards.txt")
        ; Pack is invalid...
        foundInvalidGP := CardDetection_CheckGodPackDeferred(true, cards, false) ; GP is never ignored

        if (foundInvalidGP){
            return
        }
        if (!foundInvalidGP) {
            ; If not a GP and not "ignore invalid packs", check what cards the current pack contains which make it invalid
            if (botConfig.get("ShinyCheck") && foundShiny && !foundLabel)
                foundLabel := "Shiny"
            if (botConfig.get("ImmersiveCheck") && foundImmersive && !foundLabel)
                foundLabel := "Immersive"
            if (botConfig.get("CrownCheck") && foundCrown && !foundLabel)
                foundLabel := "Crown"

            ; Report invalid cards found.
            if (foundLabel) {
                FoundStars(foundLabel)
                restartGameInstance(foundLabel . " found. Continuing...", "GodPack")
            }
        }

        IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck
        return
    }

    ; Check for god pack. if found we know its not invalid
    session.set("foundGP", CardDetection_CheckGodPackDeferred(false, cards, true))

    if (session.get("foundGP")) {
        return
    }

    ; Check for 2-star cards (for Inject Wonderpick 96P+ only)
    2starCount := false

    if (botConfig.get("PseudoGodPack") && !foundLabel) {
        2starCount := foundTrainer + foundRainbow + foundFullArt
        if (2starCount > 1)
            foundLabel := "Double two star"
    }
    if (botConfig.get("TrainerCheck") && !foundLabel && foundTrainer) {
        foundLabel := "Trainer"
    }
    if (botConfig.get("RainbowCheck") && !foundLabel && foundRainbow) {
        foundLabel := "Rainbow"
    }
    if (botConfig.get("FullArtCheck") && !foundLabel && foundFullArt) {
        foundLabel := "Full Art"
    }
    if (botConfig.get("WishlistCheck") && !foundLabel && foundWishlist2Star) {
        session.set("wishlistMatches", Wishlist_TwoStarMatchEntries(cards, rarity, session.get("wishlistMap")))
        foundLabel := "Wishlist"
    }

    if (foundLabel) {
        FinalizeInjectedGodPackAccount()
        FoundStars(foundLabel, cards)
        restartGameInstance(foundLabel . " found. Continuing...", "GodPack")
    }

}

; detectedCardCount: number of cards the Helper recognized, 0 if none
CheckPackFallback(detectedCardCount := 0) {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig, session

    currentPackIs6Card := false ; reset before each pack check
    currentPackIs6Card := false ; reset before each pack check

    UpdatePackCountAfterOpening()

    ; NEW: Disable card detection for Create Bots and Inject 13P+
    ; Only run detection for Inject Wonderpick 96P+
    skipCardDetection := (botConfig.get("deleteMethod") = "Create Bots (13P)" || botConfig.get("deleteMethod") = "Inject 13P+")

    ; If not doing card detection and no friends and s4t disabled, just return early
    if(skipCardDetection && !session.get("friendIDs") && botConfig.get("FriendID") = "" && !botConfig.get("s4tEnabled"))
        return false

    ; Determine total cards in pack for 4-diamond s4t calculations
    if (detectedCardCount > 0) {
        totalCardsInPack := detectedCardCount
    } else {
        currentPackIs4Card := DetectFourCardPack()
        if (!currentPackIs4Card) {
            currentPackIs6Card := DetectSixCardPack()
        }
        totalCardsInPack := currentPackIs6Card ? 6 : (currentPackIs4Card ? 4 : 5)
    }

    ; Wait for cards to render before checking.
    Loop {
        if (CheckCardLoading(totalCardsInPack) = 0)
            break
        Delay(1)
    }
    Delay(1)

    currentPackInfo := AnalysisBorder(totalCardsInPack)
    session.set("currentPackInfo", currentPackInfo)

    ; NEW: Check for s4t tradeable cards FIRST (before invalid/godpack checks)
    ; This allows s4t to work even on "invalid" packs with crowns/immersives/etc
    if (botConfig.get("s4tEnabled")) {
        found3Dmnd := 0
        found4Dmnd := 0
        found1Star := 0
        foundGimmighoul := 0
        foundCrown := 0
        foundImmersive := 0
        foundShiny1Star := 0
        foundShiny2Star := 0
        foundTrainer := 0
        foundRainbow := 0
        foundFullArt := 0

        ; Check all border types for s4t (only if enabled)
        if (botConfig.get("s4t3Dmnd")) {
            found3Dmnd := currentPackInfo["TypeCount"]["3diamond"]
        }
        if (botConfig.get("s4t1Star")) {
            found1Star := currentPackInfo["TypeCount"]["1star"]
        }
        if (botConfig.get("s4t4Dmnd")) {
            ; Detecting a 4-diamond EX card by subtracting other types
            found4Dmnd := totalCardsInPack - currentPackInfo["TypeCount"]["normal"]
            if (found4Dmnd > 0) {
                if (botConfig.get("s4t3Dmnd"))
                    found4Dmnd -= found3Dmnd
                else
                    found4Dmnd -= currentPackInfo["TypeCount"]["3diamond"]
            }
            if (found4Dmnd > 0) {
                if (botConfig.get("s4t1Star"))
                    found4Dmnd -= found1Star
                else
                    found4Dmnd -= currentPackInfo["TypeCount"]["1star"]
            }
            if (found4Dmnd > 0) {
                found4Dmnd -= currentPackInfo["TypeCount"]["trainer"]
                found4Dmnd -= currentPackInfo["TypeCount"]["rainbow"]
                found4Dmnd -= currentPackInfo["TypeCount"]["fullart"]
                found4Dmnd -= currentPackInfo["TypeCount"]["immersive"]
                found4Dmnd -= currentPackInfo["TypeCount"]["crown"]
                found4Dmnd -= currentPackInfo["TypeCount"]["ShinyEx"]
                found4Dmnd -= currentPackInfo["TypeCount"]["shiny1star"]
            }
        }
        if (botConfig.get("s4tGholdengo") && session.get("openPack") = "Shining") {
            foundGimmighoul := FindCard("gimmighoul")
        }

        ; NEW: Only check if the specific card type is enabled
        if (botConfig.get("s4tCrown")) {
            foundCrown := currentPackInfo["TypeCount"]["crown"]
        }
        if (botConfig.get("s4tImmersive")) {
            foundImmersive := currentPackInfo["TypeCount"]["immersive"]
        }
        if (botConfig.get("s4tShiny2Star")) {
            foundShiny2Star := currentPackInfo["TypeCount"]["ShinyEx"]
        }
        if (botConfig.get("s4tShiny1Star")) {
            foundShiny1Star := currentPackInfo["TypeCount"]["shiny1star"]
        }
        if (botConfig.get("s4tTrainer")) {
            foundTrainer := currentPackInfo["TypeCount"]["trainer"]
        }
        if (botConfig.get("s4tRainbow")) {
            foundRainbow := currentPackInfo["TypeCount"]["rainbow"]
        }
        if (botConfig.get("s4tFullArt")) {
            foundFullArt := currentPackInfo["TypeCount"]["fullart"]
        }

        foundTradeable := found3Dmnd + found4Dmnd + found1Star + foundGimmighoul + foundCrown + foundImmersive + foundShiny1Star + foundShiny2Star + foundTrainer + foundRainbow + foundFullArt

        if (foundTradeable > 0) {
            FoundTradeable(found3Dmnd, found4Dmnd, found1Star, foundGimmighoul, foundCrown, foundImmersive, foundShiny1Star, foundShiny2Star, foundTrainer, foundRainbow, foundFullArt)
            ; Continue with the rest of the run in s4t mode; don't return early.
        }
    }

    ; Skip rest of card detection if this is Create Bots or Inject 13P+
    if (skipCardDetection) {
        return false
    }

    foundLabel := false

    ; Check if the current pack is valid (for Inject Wonderpick 96P+ only now)
    foundShiny := currentPackInfo["TypeCount"]["ShinyEx"] + currentPackInfo["TypeCount"]["shiny1star"]
    foundCrown := currentPackInfo["TypeCount"]["crown"]
    foundImmersive := currentPackInfo["TypeCount"]["immersive"]
    foundInvalid := foundShiny + foundCrown + foundImmersive

    if (foundInvalid) {
        ; Pack is invalid...
        foundInvalidGP := CardDetection_CheckGodPackDeferred(true, "", false) ; GP is never ignored

        if (foundInvalidGP){
            return
        }
        if (!foundInvalidGP && !botConfig.get("InvalidCheck")) {
            ; If not a GP and not "ignore invalid packs", check what cards the current pack contains which make it invalid
            if (botConfig.get("ShinyCheck") && foundShiny && !foundLabel)
                foundLabel := "Shiny"
            if (botConfig.get("ImmersiveCheck") && foundImmersive && !foundLabel)
                foundLabel := "Immersive"
            if (botConfig.get("CrownCheck") && foundCrown && !foundLabel)
                foundLabel := "Crown"

            ; Report invalid cards found.
            if (foundLabel) {
                FoundStars(foundLabel)
                restartGameInstance(foundLabel . " found. Continuing...", "GodPack")
            }
        }

        IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck
        return
    }

    ; Check for god pack. if found we know its not invalid
    session.set("foundGP", CardDetection_CheckGodPackDeferred(false, "", true))

    if (session.get("foundGP")) {
        return
    }

    ; Check for 2-star cards (for Inject Wonderpick 96P+ only)
    foundTrainer := false
    foundRainbow := false
    foundFullArt := false
    2starCount := false

    if (botConfig.get("PseudoGodPack") && !foundLabel) {
        foundTrainer := currentPackInfo["TypeCount"]["trainer"]
        foundRainbow := currentPackInfo["TypeCount"]["rainbow"]
        foundFullArt := currentPackInfo["TypeCount"]["fullart"]
        2starCount := foundTrainer + foundRainbow + foundFullArt
        if (2starCount > 1)
            foundLabel := "Double two star"
    }
    if (botConfig.get("TrainerCheck") && !foundLabel) {
        if(!botConfig.get("PseudoGodPack"))
            foundTrainer := currentPackInfo["TypeCount"]["trainer"]
        if (foundTrainer)
            foundLabel := "Trainer"
    }
    if (botConfig.get("RainbowCheck") && !foundLabel) {
        if(!botConfig.get("PseudoGodPack"))
            foundRainbow := currentPackInfo["TypeCount"]["rainbow"]
        if (foundRainbow)
            foundLabel := "Rainbow"
    }
    if (botConfig.get("FullArtCheck") && !foundLabel) {
        if(!botConfig.get("PseudoGodPack"))
            foundFullArt := currentPackInfo["TypeCount"]["fullart"]
        if (foundFullArt)
            foundLabel := "Full Art"
    }

    if (foundLabel) {
        FinalizeInjectedGodPackAccount()
        FoundStars(foundLabel)
        restartGameInstance(foundLabel . " found. Continuing...", "GodPack")
    }
}
