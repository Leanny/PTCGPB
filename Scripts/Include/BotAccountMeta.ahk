; Account metadata helpers used by the instance script

SetBeginnerMissionsDone() {
    global session

    session.get("missionDoneList")["beginnerMissionsDone"] := 1
    deviceAccount := GetCurrentDeviceAccountForMetadata()
    if (deviceAccount != "") {
        AccountMetadata_SetLastLoggedInNow(deviceAccount, session.get("scriptName"), session.get("accountFileName"))
        if (session.get("accountFileName") != "")
            AccountMetadata_SetFlag(session.get("scriptName"), session.get("accountFileName"), "H", 1)
    }

    if (session.get("injectMethod") && session.get("loadedAccount")) {
        setMetaData()
        if (session.get("accountFileName") != "")
            AccountMetadata_SetFlag(session.get("scriptName"), session.get("accountFileName"), "H", 1)
    }
}

SetLastPackPulledNow() {
    global session

    deviceAccount := GetCurrentDeviceAccountForMetadata()
    if (deviceAccount != "")
        AccountMetadata_SetLastPackPulledNow(deviceAccount, session.get("scriptName"), session.get("accountFileName"))
}

GetCurrentDeviceAccountForMetadata() {
    global session

    deviceAccount := session.get("deviceAccount")
    if (deviceAccount = "") {
        LogDebug("Device account missing in session; reading from XML metadata")
        deviceAccount := GetDeviceAccountFromXML()
        if (deviceAccount != "") {
            LogDebug("Resolved device account from XML for " . session.get("accountFileName"))
            session.set("deviceAccount", deviceAccount)
        } else {
            LogWarn("Could not resolve device account for " . session.get("accountFileName"))
        }
    }
    return deviceAccount
}

GetAccountCreationDate() {
    global session

    if (!session.get("injectMethod") || !session.get("loadedAccount") || session.get("accountFileName") = "")
        return false

    LogDebug("GetAccountCreationDate started for " . session.get("accountFileName"))
    accountPath := A_ScriptDir . "\..\Accounts\Saved\" . session.get("scriptName") . "\" . session.get("accountFileName")
    accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), accountPath)
    existingCreatedAt := accountMeta["createdAt"]

    LogTrace("Ensuring ptcgpb helper exists before creation-date check", "ADB.txt")
    if (!EnsurePTCGPBHelperInstalled())
        return false

    LogTrace("Running ptcgpb earliest for creation-date window", "ADB.txt")
    earliestOutput := adbWriteRaw("/data/ptcgp/ptcgpb earliest", true)
    earliestOutput := StrReplace(earliestOutput, "`r")
    earliestOutput := Trim(earliestOutput, "`n`t ")
    if (!RegExMatch(earliestOutput, "(\d{9,12})", earliestMatch)) {
        LogWarn("GetAccountCreationDate could not parse earliest output for " . session.get("accountFileName") . ": " . earliestOutput)
        return false
    }

    earliestUnix := earliestMatch1 + 0
    latestUnix := earliestUnix + 86400
    LogDebug("Creation-date valid window for " . session.get("accountFileName") . ": earliestUnix=" . earliestUnix . ", latestUnix=" . latestUnix)
    normalizedExistingCreatedAt := AccountCreationDate_Normalize(existingCreatedAt)
    if (normalizedExistingCreatedAt != "") {
        existingCreatedAtUnix := AccountCreationDate_ToUnix(normalizedExistingCreatedAt)
        if (existingCreatedAtUnix >= earliestUnix && existingCreatedAtUnix <= latestUnix)
        {
            if (normalizedExistingCreatedAt != existingCreatedAt) {
                LogDebug("Normalized account createdAt from Unix timestamp for " . session.get("accountFileName"))
                accountMeta["createdAt"] := normalizedExistingCreatedAt
                AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)
            }
            session.set("accountCreatedAt", normalizedExistingCreatedAt)
            LogDebug("Using existing account createdAt for " . session.get("accountFileName"))
            return true
        }
        LogDebug("Existing account createdAt outside expected range for " . session.get("accountFileName"))
    }

    creationDate := AccountCreationDate_FromUnix(latestUnix)
    LogDebug("Defaulting createdAt to latest window bound for " . session.get("accountFileName") . ": " . creationDate)

    if (RegExMatch(session.get("accountFileName"), "^\d+P_(\d{14})_", fileMatch)) {
        fileCreationDate := fileMatch1
        fileCreationUnix := AccountCreationDate_ToUnix(fileCreationDate)
        if (fileCreationUnix >= earliestUnix && fileCreationUnix <= latestUnix) {
            creationDate := fileCreationDate
            LogDebug("Using createdAt from filename for " . session.get("accountFileName") . ": " . creationDate)
        } else {
            LogDebug("Filename createdAt outside expected range for " . session.get("accountFileName") . ": " . fileCreationDate)
        }
    }

    accountMeta["deviceAccount"] := GetCurrentDeviceAccountForMetadata()
    accountMeta["createdAt"] := creationDate
    session.set("accountCreatedAt", creationDate)
    saveOk := AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)
    if (saveOk)
        LogInfo("Saved account createdAt for " . session.get("accountFileName") . ": " . creationDate)
    else
        LogWarn("Failed to save account createdAt for " . session.get("accountFileName"))
    return saveOk
}

AccountCreationDate_Normalize(value) {
    value := Trim(value)
    if (RegExMatch(value, "^\d{14}$"))
        return value
    if (RegExMatch(value, "^\d{9,12}$"))
        return AccountCreationDate_FromUnix(value + 0)
    return ""
}

AccountCreationDate_FromUnix(unixTimestamp) {
    creationDate := "19700101000000"
    EnvAdd, creationDate, %unixTimestamp%, Seconds
    return creationDate
}

AccountCreationDate_ToUnix(creationDate) {
    unixTimestamp := creationDate
    EnvSub, unixTimestamp, 19700101000000, Seconds
    return unixTimestamp + 0
}

EnsureAccountLanguageMetadata() {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig, session

    if (session.get("accountFileName") = "")
        return false
    if ((!session.get("injectMethod") || !session.get("loadedAccount")) && botConfig.get("deleteMethod") != "Create Bots (13P)")
        return false

    deviceAccount := GetCurrentDeviceAccountForMetadata()
    if (deviceAccount = "") {
        LogWarn("EnsureAccountLanguageMetadata skipped because device account could not be resolved for " . session.get("accountFileName"))
        return false
    }

    LogTrace("Ensuring ptcgpb helper exists before language lookup", "ADB.txt")
    if (!EnsurePTCGPBHelperInstalled())
        return false

    LogTrace("Running ptcgpb language lookup", "ADB.txt")
    language := adbWriteRaw("/data/ptcgp/ptcgpb lang", true)
    language := Trim(StrReplace(language, "`r"), "`n`t ")
    if (language = "") {
        LogWarn("EnsureAccountLanguageMetadata failed because ptcgpb lang returned no language")
        return false
    }

    if (!RegExMatch(language, "i)^[a-z][a-z0-9_-]{0,15}$")) {
        LogWarn("EnsureAccountLanguageMetadata ignored unexpected language value: " . language)
        return false
    }

    session.set("language", language)

    if (!AccountMetadata_SetLanguage(deviceAccount, language, session.get("scriptName"), session.get("accountFileName"))) {
        LogWarn("EnsureAccountLanguageMetadata failed to save language for " . session.get("accountFileName"))
        return false
    }

    LogInfo("Saved account language " . language . " for " . session.get("accountFileName"))
    return true
}

GetHistoryOfAccount() {
    prof := Prof_Scope(A_ThisFunc)
    global session, botConfig

    if (!session.get("injectMethod") || !session.get("loadedAccount") || session.get("accountFileName") = "")
        return false

    LogInfo("GetHistoryOfAccount started for " . session.get("accountFileName"))
    accountPath := A_ScriptDir . "\..\Accounts\Saved\" . session.get("scriptName") . "\" . session.get("accountFileName")
    accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), accountPath)
    inDepthHistoryImport := botConfig.get("inDepthHistoryImport")

    deviceAccount := GetCurrentDeviceAccountForMetadata()
    if (deviceAccount = "") {
        LogWarn("GetHistoryOfAccount skipped because device account could not be resolved for " . session.get("accountFileName"))
        return false
    }

    if (!inDepthHistoryImport && AccountEligibility_FlagIsSet(accountMeta, "H") && AccountMetadata_AccountHasPulls(deviceAccount)) {
        LogDebug("GetHistoryOfAccount skipped because history is already imported for " . session.get("accountFileName"))
        return true
    }

    helperPath := AccountMetadata_HelperPath()
    if (!FileExist(helperPath)) {
        LogWarn("GetHistoryOfAccount skipped because carddb helper is missing at " . helperPath)
        return false
    }

    CreateStatusMessage("Importing Pack History... Please wait a bit.")
    LogDebug("Importing pack history for device account " . deviceAccount)

    safeName := RegExReplace(deviceAccount, "[^A-Za-z0-9_.-]", "_")
    filename := "history_" . safeName . ".txt"
    remotePath := "/data/ptcgp/" . filename
    sdcardPath := "/sdcard/" . filename
    localDir := A_ScriptDir . "\temp"
    if (!FileExist(localDir))
        FileCreateDir, %localDir%
    localPath := localDir . "\" . filename
    if (FileExist(localPath))
        FileDelete, %localPath%

    LogTrace("Ensuring MissionUserPrefs exists before history import", "ADB.txt")
    ensureMissionUserPrefsExist()

    adbCommand := session.get("adbPath") . " -s 127.0.0.1:" . session.get("adbPort")
    LogTrace("Ensuring ptcgpb helper exists before history import", "ADB.txt")
    if (!EnsurePTCGPBHelperInstalled())
        return false
    LogTrace("Clearing stale remote history files: " . remotePath . " and " . sdcardPath, "ADB.txt")
    adbWriteRaw("rm -f " . remotePath . " " . sdcardPath)
    LogTrace("Running ptcgpb history export to " . remotePath, "ADB.txt")
    adbWriteRaw("/data/ptcgp/ptcgpb history --out " . remotePath)
    LogTrace("Copying history export to sdcard path " . sdcardPath, "ADB.txt")
    adbWriteRaw("cp -f " . remotePath . " " . sdcardPath)

    LogTrace("Pulling history file to " . localPath, "ADB.txt")
    RunWait, % """" . session.get("adbPath") . """ -s 127.0.0.1:" . session.get("adbPort") . " pull """ . sdcardPath . """ """ . localPath . """",, Hide
    adbWriteRaw("rm -f " . remotePath . " " . sdcardPath)
    if (!FileExist(localPath)) {
        LogWarn("GetHistoryOfAccount failed because pulled history file was not created: " . localPath)
        return false
    }

    root := getScriptBaseFolder()
    LogDebug("Importing history file with carddb for device account " . deviceAccount . (inDepthHistoryImport ? " (in-depth)" : ""))
    importArgs := """" . helperPath . """ --root """ . root . """ import-history --device-account """ . deviceAccount . """ --input """ . localPath . """"
    if (inDepthHistoryImport)
        importArgs .= " --in-depth"
    RunWait, %importArgs%,, Hide
    if (ErrorLevel) {
        LogWarn("GetHistoryOfAccount carddb import-history failed for " . session.get("accountFileName") . " ErrorLevel=" . ErrorLevel)
        return false
    }

    FileDelete, %localPath%
    LogInfo("GetHistoryOfAccount completed for " . session.get("accountFileName"))
    return true
}

SetWonderPickMetadataFlag() {
    global session

    if (!session.get("injectMethod") || !session.get("loadedAccount") || session.get("accountFileName") = "")
        return

    validUntil := A_Now
    validUntil += 24, Hours
    AccountMetadata_SetFlag(session.get("scriptName"), session.get("accountFileName"), "W", 1, validUntil)
}

SetSpendHourglassMetadataFlag() {
    global session, botConfig

    if (!session.get("injectMethod") || !session.get("loadedAccount") || session.get("accountFileName") = "")
        return
    if (!botConfig.get("spendHourGlass"))
        return
    if (botConfig.get("deleteMethod") != "Inject 13P+")
        return

    validUntil := A_Now
    validUntil += 24, Hours
    AccountMetadata_SetFlag(session.get("scriptName"), session.get("accountFileName"), "SH", 1, validUntil)
}
