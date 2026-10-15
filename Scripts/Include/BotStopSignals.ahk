; Stop/exit signalling between instances and cleanup on exit

PersistStopAfterRunIfNeeded() {
    global session
    if (session.get("stopToggle"))
        IniWrite, 1, % session.get("scriptIniFile"), UserSettings, stopAfterRunPending
}

; Kill all script instances immediately
StopAllInstances() {
    global botConfig

    DetectHiddenWindows, On
    SetTitleMatchMode, 2  ; Match if title CONTAINS the string (needed for full paths)

    ; Close Main.ahk first
    WinClose, Main.ahk ahk_class AutoHotkey

    ; Close all numbered instances (2 through Instances, skip 1 which is us)
    Loop, % botConfig.get("Instances") {
        if (A_Index != 1) {
            WinClose, % A_Index ".ahk ahk_class AutoHotkey"
        }
    }

    ; Finally exit this instance
    CleanupBeforeExit()
    ExitApp
}

OnMonitorWake(wParam, lParam, msg, hwnd) {
    global session

    DelayH(3000)
    FixInstanceScreen(session.get("scriptName"))
}

; Message handler for "stop after run" signal from instance 1
OnStopAfterRunMessage(wParam, lParam, msg, hwnd) {
    global session
    LogInfo("Received stop-after-run signal from instance 1")
    session.set("stopToggle", true)
    CreateStatusMessage("Stopping script at the end of the run...",,,, false)
    return 0
}

; Send "stop after run" message to all other script instances
SignalStopAfterRun() {
    global botConfig

    DetectHiddenWindows, On
    SetTitleMatchMode, 2

    ; Send message to all numbered instances (2 through Instances)
    Loop, % botConfig.get("Instances") {
        if (A_Index != 1) {
            ; Find the window for this instance
            WinGet, targetHwnd, ID, % A_Index ".ahk ahk_class AutoHotkey"
            if (targetHwnd) {
                ; Send custom message (0x500) to signal "stop after run"
                PostMessage, 0x500, 0, 0,, ahk_id %targetHwnd%
            }
        }
    }
}

CleanupBeforeExit(){
    global session

    TerminateHelper()
    CloseCardDatabase(session.get("deviceAccount"))
    AccountMetadata_CloseTempForInstance(session.get("scriptName"))
    allSpecialEventDispose()
    GetGPUMemoryByPDH(-1, true)
}
