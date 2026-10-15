; Toggle handlers for stop, GP test, dev mode and bounding-box debugging

; ToggleStop - For GUI button clicks (stops only THIS instance)
ToggleStop() {
    global botConfig, session, dictionaryData

    ; Check if user has a saved preference for single instance stop
    botConfig.loadIniSectionFromSettingsFile("Extra")
    savedStopPreferenceSingle := (botConfig.get("stopPreferenceSingle") = "") ? "none" : botConfig.get("stopPreferenceSingle")

    if (savedStopPreferenceSingle != "none" && savedStopPreferenceSingle != "ERROR" && savedStopPreferenceSingle != "") {
        ; Execute the saved preference directly without showing popup
        if (savedStopPreferenceSingle = "immediate") {
            CleanupBeforeExit()
            ExitApp
        } else if (savedStopPreferenceSingle = "wait_end") {
            session.set("stopToggle", true)
            CreateStatusMessage("Stopping script at the end of the run...",,,, false)
        }
        return
    }

    ; Get localized strings
    title := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_confirm_title"]
    btnImmediate := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_immediately"]
    btnWaitEnd := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_wait_end"]
    chkRemember := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_remember_preference"]

    ; Create confirmation GUI with checkbox
    Gui, StopConfirm:New, +AlwaysOnTop +Owner
    Gui, StopConfirm:Add, Text, x20 y15 w260 Center, % title
    Gui, StopConfirm:Add, Button, x20 y45 w130 h30 gStopImmediatelySingle, % btnImmediate
    Gui, StopConfirm:Add, Button, x160 y45 w130 h30 gStopWaitEndSingle, % btnWaitEnd
    Gui, StopConfirm:Add, Checkbox, x20 y85 w260 hwndhRememberStopPreferenceSingle, % chkRemember
    Gui, StopConfirm:Show, w310 h115, % title

    session.set("RememberStopPreferenceSingleHwnd", hRememberStopPreferenceSingle)
    return
}

; ToggleStopAll - For Shift+F7 hotkey (stops ALL instances, only called from instance 1)
ToggleStopAll() {
    static ui_RememberStopPreference
    global botConfig, session, dictionaryData

    ; Check if user has a saved preference
    botConfig.loadIniSectionFromSettingsFile("Extra")
    savedStopPreference := (botConfig.get("stopPreference") = "") ? "none" : botConfig.get("stopPreference")

    if (savedStopPreference != "none" && savedStopPreference != "ERROR" && savedStopPreference != "") {
        ; Execute the saved preference directly without showing popup
        if (savedStopPreference = "immediate") {
            StopAllInstances()
        } else if (savedStopPreference = "wait_end") {
            SignalStopAfterRun()
            session.set("stopToggle", true)
            CreateStatusMessage("Stopping script at the end of the run...",,,, false)
        } else if (savedStopPreference = "kill_mumu") {
            Loop, % botConfig.get("Instances") {
                killInstance(A_Index)
                Sleep, 500
            }
            Sleep, 1000
            StopAllInstances()
        }
        return
    }

    ; Get localized strings
    title := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_confirm_title"]
    btnImmediate := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_immediately"]
    btnWaitEnd := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_wait_end"]
    btnKillMumu := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_kill_mumu"]
    chkRemember := dictionaryData[botConfig.get("defaultBotLanguage")]["stop_remember_preference"]

    ; Create confirmation GUI with checkbox
    Gui, StopConfirmAll:New, +AlwaysOnTop +Owner
    Gui, StopConfirmAll:Add, Text, x20 y15 w400 Center, % title
    Gui, StopConfirmAll:Add, Button, x20 y45 w130 h30 gStopImmediatelyAll, % btnImmediate
    Gui, StopConfirmAll:Add, Button, x160 y45 w130 h30 gStopWaitEndAll, % btnWaitEnd
    Gui, StopConfirmAll:Add, Button, x300 y45 w130 h30 gStopAndKillMuMuAll, % btnKillMumu
    Gui, StopConfirmAll:Add, Checkbox, x20 y85 w400 hwndhRememberStopPreference, % chkRemember
    Gui, StopConfirmAll:Show, w450 h115, % title

    session.set("RememberStopPreferenceHwnd", hRememberStopPreference)
    return
}

ToggleTestScript() {
    global session

    if(!session.get("GPTest")) {
        CreateStatusMessage("In GP Test Mode",,,, false)
        session.set("GPTest", true)
    }
    else {
        CreateStatusMessage("Exiting GP Test Mode",,,, false)
        session.set("GPTest", false)
    }
}

ToggleDevMode() {
    global session

    try {
        OwnerWND := getMuMuHwnd(session.get("winTitle"))
        if (!OwnerWND) {
            CreateStatusMessage("Failed to create button GUI. Emulator window not found.",,,, false)
            return
        }

        WinGetPos, x, y, Width, Height, ahk_id %OwnerWND%
        x4 := x + 5
        y4 := y + 44
        buttonWidth := 40

        guiSuffix := session.get("winTitle")
        Gui, DevMode%guiID%:Destroy
        Gui, DevMode%guiID%:New, +Owner%OwnerWND% +LastFound
        Gui, DevMode%guiID%:Font, s5 cGray Norm Bold, Segoe UI  ; Normal font for input labels
        Gui, DevMode%guiID%:Add, Button, % "x" . (buttonWidth * 0) . " y0 w" . buttonWidth . " h25 gbboxScript", bound box

        Gui, DevMode%guiID%:Add, Button, % "x" . (buttonWidth * 1) . " y0 w" . buttonWidth . " h25 gbboxNpauseScript", bbox pause

        Gui, DevMode%guiID%:Add, Button, % "x" . (buttonWidth * 2) . " y0 w" . buttonWidth . " h25 gscreenshotscript", screen grab
        ;Gui, DevMode%guiID%:Add, Button, % "x" . (buttonWidth * 3) . " y0 w" . buttonWidth . " h25 gStartStopRecording", Start Recording

        Gui, DevMode%guiID%:Add, Button, % "x" . (buttonWidth * 0) . " y" . (25 + 5) " w" . buttonWidth . " h25 gLogout", Logout

        Gui, DevMode%guiID%:Show, x%x4% y%y4% w250 h100, % "Dev Mode" session.get("winTitle")

    }
    catch e {
        CreateStatusMessage("Failed to create button GUI. " . e.Message,,,, false)
    }
}

ToggleBBox() {
    session.set("dbg_bbox", !session.get("dbg_bbox"))
}

TogglebboxNpause() {
    session.set("dbg_bboxNpause", !session.get("dbg_bboxNpause"))
}
