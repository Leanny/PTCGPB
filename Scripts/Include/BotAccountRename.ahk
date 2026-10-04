; Account rename flow used by the instance script

; Pick a username using AccountName prefix or usernames(_default).txt (same rules as Create Bots).
PickRenameUsername() {
    global botConfig

    if (botConfig.get("AccountName") != "ERROR" && botConfig.get("AccountName") != "") {
        Random, randomNum, 1, 500
        username := botConfig.get("AccountName") . "-" . randomNum
        username := SubStr(username, 1, 14)
        LogDebug("Rename using AccountName: " . username)
        return username
    }

    fileName := A_ScriptDir . "\..\usernames.txt"
    if (FileExist(fileName))
        name := ReadFile("usernames")
    else
        name := ReadFile("usernames_default")

    Random, randomIndex, 1, name.MaxIndex()
    username := name[randomIndex]
    username := SubStr(username, 1, 14)
    LogDebug("Rename using random username: " . username)
    return username
}

; True when current loaded account is old enough and outside rename cooldown.
; Uses metadata createdAt/lastRenamedAt; if createdAt was missing, relies on
; GetAccountCreationDate() (already run after boot) + session.accountCreatedAt.
AccountRename_CanRenameCurrentAccount() {
    global session

    accountPath := session.get("loadedAccount")
    if (accountPath = "" || session.get("accountFileName") = "")
        return false

    accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), accountPath)
    createdAt := AccountMetadata_NormalizeCreatedAt(accountMeta["createdAt"])
    sessionCreatedAt := AccountMetadata_NormalizeCreatedAt(session.get("accountCreatedAt"))
    if ((createdAt = "" || createdAt = "0") && sessionCreatedAt != "" && sessionCreatedAt != "0") {
        createdAt := sessionCreatedAt
        accountMeta["createdAt"] := createdAt
        AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)
    }
    if (createdAt != "" && createdAt != "0")
        session.set("accountCreatedAt", createdAt)

    if (!AccountEligibility_RenameAccountEligible(accountMeta)) {
        minDays := AccountEligibility_RenameMinAgeDays()
        LogInfo("Rename Account: not eligible (need " . minDays . "d since create/rename) for " . session.get("accountFileName"))
        return false
    }
    return true
}

AccountRename_RecordCooldown(reason := "") {
    global session
    if (!session.get("injectMethod") || session.get("accountFileName") = "")
        return
    accountPath := session.get("loadedAccount")
    if (accountPath = "")
        return
    accountMeta := AccountMetadata_Get(session.get("scriptName"), session.get("accountFileName"), accountPath)
    accountMeta["lastRenamedAt"] := AccountMetadata_Now()
    accountMeta["deviceAccount"] := GetCurrentDeviceAccountForMetadata()
    AccountMetadata_SaveAccount(session.get("scriptName"), session.get("accountFileName"), accountMeta)
    session.set("accountLastRenamedAt", accountMeta["lastRenamedAt"])
    if (reason != "")
        LogInfo("Rename Account: recorded lastRenamedAt (" . reason . ") for " . session.get("accountFileName"))
}

; Inject Rename Account: hamburger → profile → edit name → type username → confirm.
; Returns the applied username, or "" on failure/timeout.
DoRenameAccount() {
    prof := Prof_Scope(A_ThisFunc)
    global session

    CreateStatusMessage("Rename Account`nOpening profile...",,,, false)

    ; 1) Open hamburger until the settings-menu username arrow is visible.
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if (FindOrLoseImage("Profile_UserNameArrowInSettingMenu", 0, 0, , true))
            break
        adbClick_wbb(240, 494) ; hamburger menu button
        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Rename Account`nOpening menu... (" . failSafeTime . "/30s)")
        if (failSafeTime >= 30) {
            LogWarn("Rename Account: timed out waiting for hamburger menu arrow")
            return ""
        }
    }

    ; 2) Enter profile. Arrow gone = we left the hamburger / entered profile.
    CreateStatusMessage("Rename Account`nEntering profile...",,,, false)
    adbClick_wbb(242, 131) ; user profile row in hamburger
    Delay(1)
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    lastProfileClick := A_TickCount
    Loop {
        if (!FindOrLoseImage("Profile_UserNameArrowInSettingMenu", 0, 0, , true))
            break
        ; Still on menu — re-tap profile row, never the hamburger.
        if (A_TickCount - lastProfileClick >= 1200) {
            adbClick_wbb(242, 131)
            lastProfileClick := A_TickCount
            Delay(1)
        }
        Delay(0.25)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Rename Account`nWaiting profile... (" . failSafeTime . "/20s)")
        if (failSafeTime >= 20) {
            LogWarn("Rename Account: timed out waiting for profile entry (arrow still visible)")
            return ""
        }
    }

    ; 3) Dismiss mission / tutorial overlays on profile (top-left).
    CreateStatusMessage("Rename Account`nDismissing missions...",,,, false)
    Loop, 4 {
        adbClick_wbb(69, 156)
        Delay(0.5)
    }

    ; 4) Wait for UsernamePencil stable >= 3s (trophies/overlay can flash it).
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    pencilSeenAt := 0
    Loop {
        if (FindOrLoseImage("Profile_UsernamePencil", 0, 0, 5, true)) {
            if (pencilSeenAt = 0)
                pencilSeenAt := A_TickCount
            else if (A_TickCount - pencilSeenAt >= 3000)
                break
        } else {
            pencilSeenAt := 0
            ; Extra dismiss taps while overlays may still be covering the pencil.
            adbClick_wbb(69, 156)
            Delay(0.4)
        }

        Delay(0.25)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Rename Account`nFinding pencil... (" . failSafeTime . "/30s)")
        if (failSafeTime >= 30) {
            LogWarn("Rename Account: timed out waiting for UsernamePencil")
            return ""
        }
    }

    CreateStatusMessage("Rename Account`nOpening name editor...",,,, false)
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        adbClick_wbb(136, 278) ; edit username row
        Delay(1)

        ; 30-day rename cooldown: error popup, dismiss and skip this account.
        if (FindOrLoseImage("Profile_AlreadyRenamed", 0, 0, 8, true)) {
            CreateStatusMessage("Rename Account`nAlready renamed (30d) — skip",,,, false)
            LogInfo("Rename Account: AlreadyRenamed cooldown — skipping account")
            AccountRename_RecordCooldown("AlreadyRenamed popup")
            adbClick_wbb(133, 367)
            Delay(1)
            return ""
        }

        ; PreRename needle is a small blue curve — keep variation low to avoid false opens.
        if (FindOrLoseImage("Profile_PreRename", 0, 0, 8, true))
            break

        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Rename Account`nWaiting PreRename... (" . failSafeTime . "/45s)")
        if (failSafeTime >= 45) {
            LogWarn("Rename Account: timed out waiting for PreRename")
            return ""
        }
    }

    username := PickRenameUsername()
    if (username = "")
        return ""

    CreateStatusMessage("Rename Account`nTyping: " . username,,,, false)
    adbClick_wbb(133, 260) ; focus editable text field
    Delay(0.5)
    ; Move cursor to the end, then select all and delete (same Shift+Home+Backspace
    ; sequence as EraseInput in FriendManager). This works regardless of the
    ; cursor position when the field is focused.
    adbInputEvent("123") ; KEYCODE_MOVE_END
    Delay(0.1)
    Loop, 3 {
        adbInputEvent("59 122 67") ; Shift+Home+Backspace
        Delay(0.25)
    }
    adbInput(username)
    Delay(1)

    ; Confirm OK a couple of times on the PreRename OK region.
    Loop, 2 {
        adbClick_wbb(146, 366)
        Delay(1)
    }

    ; Success only when pencil stays visible for >= 2s (avoids flash between the two OKs).
    ; Keep tapping OK while waiting — the 2nd confirm dialog may not match PreRename.
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    pencilSeenAt := 0
    lastOkClick := 0
    Loop {
        if (FindOrLoseImage("Profile_UsernamePencil", 0, 0, 5, true)) {
            if (pencilSeenAt = 0)
                pencilSeenAt := A_TickCount
            else if (A_TickCount - pencilSeenAt >= 2000) {
                CreateStatusMessage("Rename Account`nDone: " . username,,,, false)
                LogInfo("DoRenameAccount applied username: " . username)
                return username
            }
        } else {
            pencilSeenAt := 0
            ; Pencil gone / still on OK dialog — press OK again.
            if (A_TickCount - lastOkClick >= 800) {
                adbClick_wbb(146, 366)
                lastOkClick := A_TickCount
                Delay(0.3)
            }
        }

        ; Also OK if PreRename needle is still up (first confirm page).
        if (FindOrLoseImage("Profile_PreRename", 0, 0, 8, true) && A_TickCount - lastOkClick >= 800) {
            pencilSeenAt := 0
            adbClick_wbb(146, 366)
            lastOkClick := A_TickCount
            Delay(0.3)
        }

        Delay(0.25)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Rename Account`nConfirming rename... (" . failSafeTime . "/30s)")
        if (failSafeTime >= 30) {
            LogWarn("Rename Account: rename not confirmed (pencil not stable 2s)")
            return ""
        }
    }
}
