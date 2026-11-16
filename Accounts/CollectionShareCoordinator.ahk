;===============================================================================
; CollectionShareCoordinator.ahk - Daily share task coordinator (Main.ahk only)
;
; Included by Main.ahk after HistoryImport.ahk: it re-exports the Main game
; history, re-imports the configured collection and computes the daily share
; target, writing a task file under Accounts\Cards\share\ (file names are
; described in CollectionShare.ahk).
;===============================================================================

;-------------------------------------------------------------------------------
; ShareTaskPruneOld - delete task and attempt files left by previous days
;-------------------------------------------------------------------------------
ShareTaskPruneOld(day) {
    Loop, Files, % ShareTaskDir() . "\*", F
    {
        if (RegExMatch(A_LoopFileName, "^(\d{4}-\d{2}-\d{2})_", m) && m1 < day)
            FileDelete, % A_LoopFileFullPath
    }
}

;-------------------------------------------------------------------------------
; CollectionShare_CoordinateDaily - ensure today's share task exists
;-------------------------------------------------------------------------------
CollectionShare_CoordinateDaily() {
    global session, botConfig

    static lastCheck := 0
    if ((A_TickCount - lastCheck) < 60000)
        return
    lastCheck := A_TickCount

    if (botConfig.get("deleteMethod") != "Inject Wonderpick 96P+")
        return
    mainIndex := ShareSettings_MainIndex(session.get("scriptName"))
    if (mainIndex < 1)
        return
    shareCfg := ShareSettings_MainConfig(mainIndex)
    if (!shareCfg.enabled)
        return

    day := ShareTaskDay()
    dir := ShareTaskDir()
    instanceName := session.get("scriptName")
    ; Any file of this Main for today, in whatever state, closes the day for it
    Loop, Files, % dir . "\" . day . "_" . instanceName . "_*", F
        return

    collection := shareCfg.collection
    friendCode := shareCfg.friendCode
    if (collection = "" || friendCode = "")
        return

    ShareTaskPruneOld(day)

    LogInfo("CollectionShare: computing daily share target for " . session.get("scriptName"))
    localPath := ""
    exportResult := ExportGameHistoryToFile(localPath)
    if (!IsObject(exportResult) || !exportResult.ok) {
        LogWarn("CollectionShare: history export failed, will retry later")
        return
    }
    deviceAccount := exportResult.deviceAccount
    if (!FileExist(dir))
        FileCreateDir, % dir

    helperPath := AccountMetadata_HelperPath()
    if (!FileExist(helperPath)) {
        LogWarn("CollectionShare: carddb helper missing, cannot compute share target")
        return
    }
    root := getScriptBaseFolder()

    importArgs := """" . helperPath . """ --root """ . root . """ import-collection --device-account """ . deviceAccount . """ --input """ . localPath . """ --instance """ . instanceName . """ --into """ . collection . """"
    RunWait, % importArgs, , Hide
    importExitCode := ErrorLevel
    FileDelete, % localPath
    if (importExitCode) {
        LogWarn("CollectionShare: import-collection failed, will retry later")
        return
    }
    InvalidateDashboardAccountsCache()

    outFile := A_Temp . "\ptcgpb_share_target_" . instanceName . ".json"
    FileDelete, % outFile
    targetArgs := """" . helperPath . """ --root """ . root . """ share-target --collection """ . collection . """ --sort """ . shareCfg.sort . """ --out """ . outFile . """"
    if (shareCfg.expansion != "")
        targetArgs .= " --expansion """ . shareCfg.expansion . """"
    RunWait, % targetArgs, , Hide
    if (!FileExist(outFile)) {
        LogWarn("CollectionShare: share-target produced no output, will retry later")
        return
    }
    FileRead, targetJson, % outFile
    FileDelete, % outFile

    if (!RegExMatch(targetJson, """cardId""\s*:\s*""([^""]+)""", m) || m1 = "") {
        skipLine := "{""day"":""" . day . """,""mainInstance"":""" . instanceName . """,""collection"":""" . collection . """,""reason"":""no account owns a card this collection is missing""}" . "`n"
        FileAppend, %skipLine%, % ShareTaskPath(day, instanceName, "no-card-available")
        LogInfo("CollectionShare: no shareable card for " . instanceName . " today")
        return
    }

    cardId := m1
    ; A pick equal to the current latest needs no picker navigation on the
    ; donor: the card screen already shows that expansion by default.
    taskExpansion := (shareCfg.expansion != "" && shareCfg.expansion != ShareExpansionLatestCode()) ? shareCfg.expansion : ""
    taskLine := "{""day"":""" . day . """,""mainInstance"":""" . instanceName . """,""collection"":""" . collection . """,""cardId"":""" . cardId . """,""sortMode"":""" . shareCfg.sort . """,""friendCode"":""" . friendCode . """,""expansion"":""" . taskExpansion . """}" . "`n"
    FileAppend, %taskLine%, % ShareTaskPath(day, instanceName, "waiting-for-donor")
    LogInfo("CollectionShare: daily share target set: " . cardId . " -> " . instanceName)
}
