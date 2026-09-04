global errorImageList := ["Common_Error"
    , "Common_Error_Cache"
    , "Common_Error_NoResponse"
    , "Common_Error_NoResponseDark"
    , "Common_Error_NoBackground_1Button"
    , "Common_Error_3ButtonError_Nodata"]
global errorFuncList := {}
global interceptProc := false

errorFuncList["Common_Error"] := Func("procError_Common")
errorFuncList["Common_Error_Cache"] := Func("procError_Cache")
errorFuncList["Common_Error_NoResponse"] := Func("procError_NoResponse")
errorFuncList["Common_Error_NoResponseDark"] := Func("procError_NoResponseDark")
errorFuncList["Common_Error_NoBackground_1Button"] := Func("procError_Common")
errorFuncList["Common_Error_3ButtonError_Nodata"] := Func("procError_NoSaveData")

ErrorCheckInScreen(pBitmap, searchVariation := 20){
    global needlesDict, errorImageList, errorFuncList, interceptProc

    imagePath := A_ScriptDir . "\Needles\"
    For key, value in errorImageList {
        needleObj := needlesDict.Get(value)

        Path := imagePath . needleObj.imageName . ".png"
        pNeedle := GetNeedle(Path)
        vRet := Gdip_ImageSearch_wbb(pBitmap, pNeedle, vPosXY
            , needleObj.coords.startX
            , needleObj.coords.startY
            , needleObj.coords.endX
            , needleObj.coords.endY
            , searchVariation)
        if (vRet = 1 && !interceptProc) {
            errorFuncList[value].Call()
        }
    }

}

procError_Common(){
    CreateStatusMessage("Found error message in " . A_ScriptName . ". Clicking Button...",,,, false)
    adbClick_wbb(137, 380)
    Sleep, 1000
}

procError_Cache(){
    global botConfig
    static lastClickAttempt := 0

    if (lastClickAttempt = 0 || A_TickCount - lastClickAttempt > 30000) {
        lastClickAttempt := A_TickCount
        CreateStatusMessage("Cache error detected. Clicking X to close popup...",,,, false)
        adbClick_wbb(137, 430)
        Sleep, 2500
        return
    }

    if(botConfig.get("heartBeatOwnerWebHookURL") != "")
        LogToDiscord(A_ScriptName . " It appears a cache deletion error message appeared on the instance, and the X close click did not recover it. Delete the instance, then copy it and reload the script.",, true,,, botConfig.get("heartBeatOwnerWebHookURL"))

    Pause, On
    return
}

procError_NoResponse(){
    CreateStatusMessage("No response in " . A_ScriptName . ". Clicking retry...",,,, false)
    adbClick_wbb(46, 299)
    Sleep, 1000
}

procError_NoResponseDark(){
    CreateStatusMessage("No response in " . A_ScriptName . ". Clicking retry...",,,, false)
    adbClick_wbb(46, 299)
    Sleep, 1000
}

procError_NoSaveData(){
    global botConfig, session

    bannedDir := getScriptBaseFolder() . "\Accounts\banned"
    archivedFiles := ""
    archiveErrors := ""

    if !FileExist(bannedDir) {
        FileCreateDir, %bannedDir%
        if (ErrorLevel)
            archiveErrors .= "`n- Could not create Accounts\banned."
    }

    xmlSource := session.get("loadedAccount")
    if (xmlSource = "" && session.get("loadDir") != "" && session.get("accountFileName") != "")
        xmlSource := session.get("loadDir") . "\" . session.get("accountFileName")

    deviceAccount := ""
    if (xmlSource != "" && FileExist(xmlSource)) {
        deviceAccount := AccountMetadata_GetDeviceAccountFromFile(xmlSource)
        SplitPath, xmlSource, xmlFileName
        xmlDestination := bannedDir . "\" . xmlFileName
        FileMove, %xmlSource%, %xmlDestination%, 1
        if (ErrorLevel)
            archiveErrors .= "`n- Could not move XML: " . xmlSource
        else
            archivedFiles .= "`n- " . xmlFileName
    } else {
        archiveErrors .= "`n- The active account XML could not be found."
    }

    if (deviceAccount = "")
        deviceAccount := session.get("deviceAccount")

    if (deviceAccount != "") {
        jsonSource := AccountMetadata_AccountPath(deviceAccount)
        if (FileExist(jsonSource)) {
            SplitPath, jsonSource, jsonFileName
            jsonDestination := bannedDir . "\" . jsonFileName
            FileMove, %jsonSource%, %jsonDestination%, 1
            if (ErrorLevel)
                archiveErrors .= "`n- Could not move JSON: " . jsonSource
            else
                archivedFiles .= "`n- " . jsonFileName
        } else {
            archiveErrors .= "`n- No metadata JSON was found for device account " . deviceAccount . "."
        }
    } else {
        archiveErrors .= "`n- The device account could not be resolved, so its metadata JSON could not be found."
    }

    message := A_ScriptName . " detected an error indicating that no save data exists, or that an unknown account error occurred."
    if (archivedFiles != "")
        message .= "`nMoved the following account files to Accounts\banned:" . archivedFiles
    if (archiveErrors != "")
        message .= "`nSome account files could not be archived:" . archiveErrors
    message .= "`nThe bot is currently paused. Please resolve the error and reload."

    LogToDiscord(message,, true,,, botConfig.get("heartBeatOwnerWebHookURL"))
    LogInfo("Restarted game. Reason: Banned account found")
    CleanupBeforeExit()
    SafeReload("Banned account found")
    return
}
