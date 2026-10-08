global ScriptDir := RegExReplace(A_LineFile, "\\[^\\]+$"), LogsDir := ScriptDir . "\..\..\Logs"
global Debug, discordWebhookURL, discordUserId, sendAccountXml, botConfig
global DEFAULT_STATUS_MESSAGE := "..."

; Read settings.
settingsPath := ScriptDir . "\..\..\Settings.ini"

IniRead, discordWebhookURL, %settingsPath%, UserSettings, discordWebhookURL
if (discordWebhookURL = "ERROR" || discordWebhookURL = "")
    IniRead, discordWebhookURL, %settingsPath%, Wonderpick, discordWebhookURL
if (discordWebhookURL = "ERROR")
    discordWebhookURL := ""
IniRead, discordUserId, %settingsPath%, UserSettings, discordUserId
if (discordUserId = "ERROR" || discordUserId = "")
    IniRead, discordUserId, %settingsPath%, Wonderpick, discordUserId
if (discordUserId = "ERROR")
    discordUserId := ""
IniRead, sendAccountXml, %settingsPath%, UserSettings, sendAccountXml, 0
if (sendAccountXml = "ERROR" || sendAccountXml = "")
    IniRead, sendAccountXml, %settingsPath%, Wonderpick, sendAccountXml, 0
IniRead, Debug, %settingsPath%, UserSettings, debugMode, 0

; Enable debugging to get more status messages and logging.

ResetStatusMessage() {
    CreateStatusMessage(DEFAULT_STATUS_MESSAGE,,,, false, true)
}

CreateStatusMessage(Message, GuiName := "StatusMessage", X := 0, Y := 565, debugOnly := true, Persist := false) {
    global session

    static hwnds := {}
    static resetStatusFunc := Func("ResetStatusMessage")
    static timerReposition
    if (!timerReposition)
        timerReposition := Func("SetReposition")

    if (Message != DEFAULT_STATUS_MESSAGE)
        LogDebug(GuiName . ": " . Message)

    Cockpit_WriteLiveMetrics(Message)

    guiWidth := 275
    guiheight := 40
    if(GuiName = "AvgRuns" || GuiName = "AutoGPTest" || GuiName = "AccountInfo")
        guiheight := 30

    if(GuiName = "AccountInfo"){
        guiWidth := 260
        guiheight := 25
    }

    try {

        ; Check if GUI with this name already exists.
        GuiName := GuiName . session.get("scriptName")

        if !hwnds.HasKey(GuiName) {
            WinGetPos, xpos, ypos, Width, Height, % session.get("winTitle") . " ahk_class Qt5156QWindowIcon"
            X := X + xpos + 5 -1
            Y := Y + ypos + 5 - 11
            if (!X)
                X := 0
            if (!Y)
                Y := 0

            ; Create a new GUI with the given name, position, and message
            Gui, %GuiName%:New, -AlwaysOnTop +ToolWindow -Caption -DPIScale
            Gui, %GuiName%:Margin, 2, 2  ; Set margin for the GUI
            Gui, %GuiName%:Font, s8  ; Set the font size to 8 (adjust as needed)
            Gui, %GuiName%:Add, Text, hwndhCtrl,
            hwnds[GuiName] := hCtrl
            OwnerWND := WinExist(session.get("winTitle") . " ahk_class Qt5156QWindowIcon")
            if(OwnerWND){
                Gui, %GuiName%:+Owner%OwnerWND% +LastFound
                DllCall("SetWindowPos", "Ptr", WinExist(), "Ptr", 1  ; HWND_BOTTOM
                    , "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)  ; SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE

                Gui, %GuiName%:Show, NoActivate x%X% y%Y% w%guiWidth% h%guiheight%
            }
            if (!isController)
                SetTimer, % timerReposition, 2000
        }
        if (isController) {
            ; Force the window to exist (hidden) so SendMessage can find it.
            Gui, %GuiName%:Show, Hide
            return
        }
        SetTextAndResize(hwnds[GuiName], Message)
        Gui, %GuiName%:Show, NoActivate  w%guiWidth% h%guiheight%

        ; Clear any previous timers.
        SetTimer, % resetStatusFunc, Off

        if (!Debug && !Persist) {
            ; Reset status message to default after 2 seconds.
            SetTimer, % resetStatusFunc, -2000
        }
    }
}

Cockpit_WriteLiveMetrics(message) {
    global session

    if (!IsObject(session))
        return

    scriptName := session.get("scriptName")
    if (scriptName = "")
        return

    if !(RegExMatch(scriptName, "^\d+$") || scriptName = "Main")
        return
    return
}

SetReposition(){
    global session

    PosOption := ""
    GuiName := "StatusMessage" . session.get("scriptName")
    instanceHwnd := WinExist(session.get("winTitle") . " ahk_class Qt5156QWindowIcon")

    if(instanceHwnd){
        WinGetPos, xpos, ypos, Width, Height, % session.get("winTitle") . " ahk_class Qt5156QWindowIcon"
        X := xpos + 5 -1
        Y := ypos + 5 + 565 - 11

        if (!X)
            X := 0
        if (!Y)
            Y := 0

        Gui, %GuiName%:+LastFound
        CurrentHwnd := WinExist()
        WinGetPos, CurX, CurY,,, ahk_id %CurrentHwnd%

        if(CurX == X && CurY == Y)
            return

        PosOption := "x" . X . " y" . Y
    }
    else
        return

    Gui, %GuiName%:Show, NoActivate %PosOption%
}

;Modified from https://stackoverflow.com/a/49354127
SetTextAndResize(controlHwnd, newText) {
    dc := DllCall("GetDC", "Ptr", controlHwnd)

    ; 0x31 = WM_GETFONT
    SendMessage 0x31,,,, ahk_id %controlHwnd%
    hFont := ErrorLevel
    oldFont := 0
    if (hFont != "FAIL")
        oldFont := DllCall("SelectObject", "Ptr", dc, "Ptr", hFont)

    VarSetCapacity(rect, 16, 0)
    ; 0x440 = DT_CALCRECT | DT_EXPANDTABS
    h := DllCall("DrawText", "Ptr", dc, "Ptr", &newText, "Int", -1, "Ptr", &rect, "UInt", 0x440)
    ; width = rect.right - rect.left
    w := NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int")

    if oldFont
        DllCall("SelectObject", "Ptr", dc, "Ptr", oldFont)
    DllCall("ReleaseDC", "Ptr", controlHwnd, "Ptr", dc)

    GuiControl,, %controlHwnd%, %newText%
    GuiControl MoveDraw, %controlHwnd%, % "h" h " w" w
}

LogToFile(message, logFile := "") {
    ; FileAppend cannot create its parent directory. Without this guard a fresh
    ; install (or a deleted Logs folder) would leave the retry loop below
    ; running forever.
    if !InStr(FileExist(LogsDir), "D") {
        FileCreateDir, %LogsDir%
        if !InStr(FileExist(LogsDir), "D")
            return false
    }

    if (logFile = "") {
        logFile := LogsDir . "\Log_" . StrReplace(A_ScriptName, ".ahk") . ".txt"
    }
    else
        logFile := LogsDir . "\" . logFile
    readableTime := LogTimestamp()

    ; Keep the existing short retries for transient sharing violations, but do
    ; not hang the bot indefinitely when the destination is not writable.
    Loop, 100 {
        FileAppend, % "[" readableTime "] " message "`n", %logFile%
        if !ErrorLevel
            return true
        Sleep, 10
    }
    return false
}

; Locale-independent and sortable, so log retention can parse it back and
; entries from different files can be lined up when reading a bug report.
LogTimestamp() {
    FormatTime, readableTime, %A_Now%, yyyy-MM-dd HH:mm:ss
    return readableTime . "." . A_MSec
}

; =================== Log retention ===================
; Deletes files in Logs\ that were not written within the retention window and
; drops entries older than the window from the files that remain. Run it only
; while no bot instance is writing (GUI startup / before Start launches them).
CleanupLogs(retentionDays := 7) {
    if !InStr(FileExist(LogsDir), "D")
        return

    cutoff := A_Now
    cutoff += -retentionDays, Days

    deletedFiles := 0
    trimmedFiles := 0
    Loop, Files, %LogsDir%\*, FR
    {
        if (A_LoopFileName = ".gitkeep")
            continue
        if (A_LoopFileTimeModified < cutoff) {
            FileDelete, %A_LoopFileFullPath%
            if (!ErrorLevel)
                deletedFiles++
            continue
        }
        ; Subfolders (e.g. Logs\failed) hold raw diagnostic dumps, not our log
        ; format, so they are only aged out as whole files.
        if (A_LoopFileDir != LogsDir)
            continue
        result := TrimLogFileBefore(A_LoopFileFullPath, cutoff)
        if (result = "deleted")
            deletedFiles++
        else if (result = "trimmed")
            trimmedFiles++
    }

    ; Remove subfolders that are empty now (FileRemoveDir fails on non-empty ones).
    Loop, Files, %LogsDir%\*, DR
        FileRemoveDir, %A_LoopFileFullPath%

    if (deletedFiles || trimmedFiles)
        LogToFile("[info] Log cleanup | kept last " . retentionDays . " days | deleted files=" . deletedFiles . " | trimmed files=" . trimmedFiles)
}

; Removes every entry stamped before cutoff. Lines without a timestamp (multi-line
; entries) stay with the entry they follow. Files without any parseable old
; timestamp are left untouched. Returns "", "trimmed" or "deleted".
TrimLogFileBefore(filePath, cutoff) {
    f := FileOpen(filePath, "r")
    if (!IsObject(f))
        return ""

    bomLength := f.Pos
    keepFrom := -1
    sawOldEntry := false
    while (!f.AtEOF) {
        linePos := f.Pos
        stamp := ParseLogTimestamp(f.ReadLine())
        if (stamp = "")
            continue
        if (stamp >= cutoff) {
            keepFrom := linePos
            break
        }
        sawOldEntry := true
    }

    if (!sawOldEntry) {
        f.Close()
        return ""
    }

    if (keepFrom < 0) {
        f.Close()
        FileDelete, %filePath%
        return ErrorLevel ? "" : "deleted"
    }

    ; Copy raw bytes so the file encoding is preserved exactly.
    tmpPath := filePath . ".tmp"
    out := FileOpen(tmpPath, "w", "CP0")
    if (!IsObject(out)) {
        f.Close()
        return ""
    }
    if (bomLength > 0) {
        f.Pos := 0
        f.RawRead(bom, bomLength)
        out.RawWrite(bom, bomLength)
    }
    f.Pos := keepFrom
    VarSetCapacity(chunk, 1048576)
    while (bytesRead := f.RawRead(chunk, 1048576))
        out.RawWrite(chunk, bytesRead)
    out.Close()
    f.Close()

    FileMove, %tmpPath%, %filePath%, 1
    if (ErrorLevel) {
        FileDelete, %tmpPath%
        return ""
    }
    return "trimmed"
}

; Returns the entry time as YYYYMMDDHH24MISS, or "" when the line does not start
; with a timestamp. Understands the current "yyyy-MM-dd HH:mm:ss" stamps and the
; older locale-dependent "[MMMM dd, yyyy HH:mm:ss]" ones.
ParseLogTimestamp(line) {
    if (RegExMatch(line, "^\[?(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})", m))
        return m1 . m2 . m3 . m4 . m5 . m6
    if (RegExMatch(line, "^\[(\S+) (\d{2}), (\d{4}) (\d{2}):(\d{2}):(\d{2})\]", m)) {
        month := LogMonthNumber(m1)
        if (month != "")
            return m3 . month . m2 . m4 . m5 . m6
    }
    return ""
}

LogMonthNumber(monthName) {
    static months := ""
    if (!IsObject(months)) {
        ; Legacy stamps used the user's locale; English covers logs copied from
        ; another machine.
        months := {}
        englishMonths := ["January", "February", "March", "April", "May", "June", "July"
            , "August", "September", "October", "November", "December"]
        Loop, 12 {
            month := Format("{:02}", A_Index)
            months[englishMonths[A_Index]] := month
            FormatTime, localName, 2000%month%01, MMMM
            months[localName] := month
        }
    }
    return months.HasKey(monthName) ? months[monthName] : ""
}

LogLevelValue(level) {
    level := Trim(level)
    StringLower, level, level
    if (level = "error")
        return 0
    if (level = "warn" || level = "warning")
        return 1
    if (level = "info")
        return 2
    if (level = "debug")
        return 3
    if (level = "trace")
        return 4
    return 2
}

LogConfiguredLevel() {
    global botConfig, Debug

    configured := "info"
    if (IsObject(botConfig)) {
        configured := botConfig.get("logLevel")
        if (configured = "")
            configured := "info"
        if (botConfig.get("verboseLogging") && LogLevelValue(configured) < LogLevelValue("debug"))
            configured := "debug"
    } else if (Debug) {
        configured := "debug"
    }
    return configured
}

ShouldLog(level := "info") {
    return LogLevelValue(level) <= LogLevelValue(LogConfiguredLevel())
}

LogMessage(level, message, logFile := "") {
    level := Trim(level)
    if (level = "")
        level := "info"
    StringLower, level, level
    if (!ShouldLog(level))
        return
    LogToFile("[" . level . "] " . message, logFile)
}

LogError(message, logFile := "") {
    LogMessage("error", message, logFile)
}

LogWarn(message, logFile := "") {
    LogMessage("warn", message, logFile)
}

LogInfo(message, logFile := "") {
    LogMessage("info", message, logFile)
}

LogDebug(message, logFile := "") {
    LogMessage("debug", message, logFile)
}

LogTrace(message, logFile := "") {
    LogMessage("trace", message, logFile)
}

LogSettingsSnapshotForRun(settingsFile := "") {
    if (settingsFile = "")
        settingsFile := getScriptBaseFolder() . "\Settings.ini"

    if (!FileExist(settingsFile)) {
        LogToFile("[warn] Run settings snapshot unavailable: Settings.ini was not found.")
        return false
    }

    FileRead, settingsContents, %settingsFile%
    if (ErrorLevel) {
        LogToFile("[warn] Run settings snapshot unavailable: Settings.ini could not be read.")
        return false
    }

    sanitizedSettings := ""
    Loop, Parse, settingsContents, `n, `r
        sanitizedSettings .= RedactSettingsLine(A_LoopField) . "`n"

    ; Bypass level filtering: every explicitly started run needs this diagnostic context.
    LogToFile("[info] Run settings snapshot (URLs redacted):`n" . RTrim(sanitizedSettings, "`r`n"))
    return true
}

RedactSettingsLine(line) {
    equalPos := InStr(line, "=")
    if (equalPos > 0) {
        key := Trim(SubStr(line, 1, equalPos - 1))
        value := SubStr(line, equalPos + 1)

        ; URL settings commonly contain credentials (for example Discord webhooks).
        ; Keep the key in the diagnostic snapshot, but never write its value.
        if (value != "" && (InStr(key, "url", false) || InStr(key, "webhook", false)))
            value := "<redacted URL>"
        else
            value := RegExReplace(value, "i)\b[a-z][a-z0-9+.-]*://\S+|\bwww\.\S+", "<redacted URL>")

        return SubStr(line, 1, equalPos) . value
    }
    ; Also protect URLs that might appear in comments or non-key lines.
    return RegExReplace(line, "i)\b[a-z][a-z0-9+.-]*://\S+|\bwww\.\S+", "<redacted URL>")
}

; Reads key=value lines (section headers ignored; keys are unique across
; sections) into an object with URL values redacted. Returns "" if unreadable.
ReadRedactedSettings(filePath) {
    if (!FileExist(filePath))
        return ""
    FileRead, contents, %filePath%
    if (ErrorLevel)
        return ""

    settings := {}
    Loop, Parse, contents, `n, `r
    {
        line := RedactSettingsLine(A_LoopField)
        equalPos := InStr(line, "=")
        if (equalPos <= 1 || SubStr(LTrim(line), 1, 1) = ";")
            continue
        settings[Trim(SubStr(line, 1, equalPos - 1))] := SubStr(line, equalPos + 1)
    }
    return settings
}

; Logs which settings differ from the ones used at the previous Start, so a bug
; report shows what the user changed before a problem appeared. The previous
; values are kept (redacted) in Logs\SettingsAtLastStart.txt.
LogSettingsChangesSinceLastStart(settingsFile) {
    current := ReadRedactedSettings(settingsFile)
    if (!IsObject(current))
        return

    previousFile := LogsDir . "\SettingsAtLastStart.txt"
    previous := ReadRedactedSettings(previousFile)
    if (IsObject(previous)) {
        changes := ""
        changeCount := 0
        for key, value in current {
            if (previous.HasKey(key) && previous[key] == value)
                continue
            changes .= "`n    " . key . ": " . (previous.HasKey(key) ? previous[key] : "<unset>") . " -> " . value
            changeCount++
        }
        for key, value in previous {
            if (current.HasKey(key))
                continue
            changes .= "`n    " . key . ": " . value . " -> <unset>"
            changeCount++
        }
        if (changeCount)
            LogToFile("[info] Settings changed since last start (" . changeCount . "):" . changes)
        else
            LogToFile("[info] Settings unchanged since last start")
    }

    stored := ""
    for key, value in current
        stored .= key . "=" . value . "`n"
    FileDelete, %previousFile%
    FileAppend, %stored%, %previousFile%
}

; Logs at most once per intervalSec for the same key, so conditions that are
; detected on every poll (error popups, waits) do not flood the log.
LogThrottled(level, key, message, intervalSec := 60, logFile := "") {
    static lastLogged := {}
    if (lastLogged.HasKey(key) && A_TickCount - lastLogged[key] < intervalSec * 1000)
        return
    lastLogged[key] := A_TickCount
    LogMessage(level, message, logFile)
}

; High-level entries for things the user did (button, hotkey, menu). They use
; a fixed prefix so a bug report can be filtered down to them.
LogUserAction(action, details := "") {
    LogInfo("User action | " . action . (details != "" ? " | " . details : ""))
}

GetActiveDiscordProfile() {
    global botConfig, discordWebhookURL, discordUserId, sendAccountXml

    profile := {"name": "Solo", "webhookURL": discordWebhookURL, "userId": discordUserId, "sendAccountXml": sendAccountXml}

    if (!IsObject(botConfig))
        return profile

    if (botConfig.get("groupRerollEnabled")) {
        profile.name := "Group Reroll"
        profile.webhookURL := botConfig.get("groupRerollDiscordWebhookURL")
        profile.userId := botConfig.get("groupRerollDiscordUserId")
        profile.sendAccountXml := botConfig.get("groupRerollSendAccountXml")
    } else {
        profile.webhookURL := botConfig.get("discordWebhookURL")
        profile.userId := botConfig.get("discordUserId")
        profile.sendAccountXml := botConfig.get("sendAccountXml")
    }

    return profile
}

DiscordShouldSendAccountXml() {
    profile := GetActiveDiscordProfile()
    return profile.sendAccountXml
}

LogMissingDiscordWebhook(profileName) {
    static warnedProfiles := {}

    if (warnedProfiles.HasKey(profileName))
        return

    warnedProfiles[profileName] := true
    LogWarn(profileName . " Discord webhook URL is not configured. Message was not sent.", "Discord.txt")
    CreateStatusMessage(profileName . " Discord webhook missing.",,,, false)
}

LogToDiscord(message, screenshotFile := "", ping := false, xmlFile := "", screenshotFile2 := "", altWebhookURL := "", altUserId := "", logSuccessfulDelivery := true) {
    profile := GetActiveDiscordProfile()
    discordPing := ""

    if (ping) {
        userId := (altUserId ? altUserId : profile.userId)

        if (userId)
            discordPing := "<@" . userId . "> "
        discordFriends := ReadFile("discord")
        if (discordFriends) {
            for index, value in discordFriends {
                if (value = "" || value = userId)
                    continue
                discordPing .= "<@" . value . "> "
            }
        }
    }

    webhookURL := (altWebhookURL ? altWebhookURL : profile.webhookURL)

    if (webhookURL = "") {
        if (!altWebhookURL)
            LogMissingDiscordWebhook(profile.name)
        return
    }

    if (webhookURL != "") {
        MaxRetries := 3
        RetryCount := 0
        discordTraceId := CreateDiscordTraceId()

        if (!IsDiscordWebhookURLWellFormed(webhookURL)) {
            LogToFile("Discord send skipped | trace=" . discordTraceId . " | reason=webhook is not a URL (expected https://discord.com/api/webhooks/...) | webhook=" . RedactDiscordWebhookURL(webhookURL), "Discord.txt")
            CreateStatusMessage("Discord webhook URL is invalid.",,,, false)
            return
        }

        curlChar := GetDiscordCurlBaseCommand()

        payloadFile := CreateDiscordPayloadFile(discordPing . message)
        if (payloadFile = "") {
            LogToFile("Discord send failed before curl | trace=" . discordTraceId . " | reason=could not create payload file | webhook=" . RedactDiscordWebhookURL(webhookURL), "Discord.txt")
            return
        }

        Loop {
            RetryCount++
            try {
                ; Base command
                curlCommand := curlChar . "-F ""payload_json=<" . payloadFile . ";type=application/json;charset=UTF-8"" "

                ; If an screenshot or xml file is provided, send it
                sendScreenshot1 := screenshotFile != "" && FileExist(screenshotFile)
                sendScreenshot2 := screenshotFile2 != "" && FileExist(screenshotFile2)
                sendXmlFile := xmlFile != "" && FileExist(xmlFile)
                fileCount := sendScreenshot1 + sendScreenshot2 + sendXmlFile
                if (sendScreenshot1 + sendScreenshot2 + sendXmlFile > 1) {
                    fileIndex := 0
                    if (sendScreenshot1) {
                        fileIndex++
                        curlCommand := curlCommand . "-F ""file" . fileIndex . "=@" . screenshotFile . """ "
                    }
                    if (sendScreenshot2) {
                        fileIndex++
                        curlCommand := curlCommand . "-F ""file" . fileIndex . "=@" . screenshotFile2 . """ "
                    }
                    if (sendXmlFile) {
                        fileIndex++
                        curlCommand := curlCommand . "-F ""file" . fileIndex . "=@" . xmlFile . """ "
                    }
                }
                else if (sendScreenshot1 + sendScreenshot2 + sendXmlFile == 1) {
                    if (sendScreenshot1)
                        curlCommand := curlCommand . "-F ""file=@" . screenshotFile . """ "
                    if (sendScreenshot2)
                        curlCommand := curlCommand . "-F ""file=@" . screenshotFile2 . """ "
                    if (sendXmlFile)
                        curlCommand := curlCommand . "-F ""file=@" . xmlFile . """ "
                }
                ; Add the webhook
                curlCommand := curlCommand . """" . webhookURL . """"

                if (logSuccessfulDelivery)
                    LogDebug("Discord send attempt | trace=" . discordTraceId . " | attempt=" . RetryCount . "/" . MaxRetries . " | webhook=" . RedactDiscordWebhookURL(webhookURL) . " | files=" . fileCount . " | messageLen=" . StrLen(message), "Discord.txt")

                ; Send the message using curl
                if (IsFunc("CmdRet")) {
                    cmdFn := Func("CmdRet")
                    curlResult := cmdFn.Call(curlCommand)
                } else {
                    RunWait, %curlCommand%,, Hide
                    curlResult := "HTTP_STATUS:" . ErrorLevel
                }

                httpStatus := GetDiscordCurlHttpStatus(curlResult)
                if (httpStatus >= 200 && httpStatus < 300) {
                    if (logSuccessfulDelivery || RetryCount > 1)
                        LogDebug("Discord send complete | trace=" . discordTraceId . " | status=" . httpStatus . " | webhook=" . RedactDiscordWebhookURL(webhookURL) . " | files=" . fileCount . " | messageLen=" . StrLen(message), "Discord.txt")
                    break
                }

                LogToFile("Discord send failed | trace=" . discordTraceId . " | attempt=" . RetryCount . "/" . MaxRetries . " | status=" . httpStatus . " | webhook=" . RedactDiscordWebhookURL(webhookURL) . " | files=" . fileCount . " | result=" . TrimDiscordCurlResult(curlResult), "Discord.txt")
            }
            catch e {
                LogToFile("Discord send exception | trace=" . discordTraceId . " | attempt=" . RetryCount . "/" . MaxRetries . " | webhook=" . RedactDiscordWebhookURL(webhookURL) . " | error=" . FormatDiscordException(e), "Discord.txt")
            }

            if (RetryCount >= MaxRetries) {
                CreateStatusMessage("Failed to send discord message.")
                break
            }
            Sleep, % 1000 * RetryCount
        }

        FileDelete, %payloadFile%
    }
}

GetDiscordCurlBaseCommand() {
    proxyEnabled := false
    proxyServer := ""
    try {
        RegRead, proxyEnabled, HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings, ProxyEnable
        RegRead, proxyServer, HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings, ProxyServer
    } catch {
        proxyEnabled := false
        proxyServer := ""
    }

    curlChar := "curl.exe -k -sS --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 60 -o NUL -w ""HTTP_STATUS:%{http_code}"" "
    if (proxyEnabled && proxyServer != "")
        curlChar .= "-x """ . proxyServer . """ "
    return curlChar
}

; Anything that is not an http(s) URL is handed to curl as a host name and fails with a confusing DNS error.
IsDiscordWebhookURLWellFormed(webhookURL) {
    return RegExMatch(Trim(webhookURL), "i)^https?://[^\s/]+/\S+")
}

IsDiscordWebhookURL(webhookURL) {
    return RegExMatch(Trim(webhookURL), "i)^https://((canary|ptb)\.)?discord(app)?\.com/api/(v\d+/)?webhooks/\d+/[\w-]+")
}

; Posts a test message and returns {ok: bool, status: int, message: string} describing the outcome.
TestDiscordWebhook(webhookURL, label := "") {
    webhookURL := Trim(webhookURL)
    result := {"ok": false, "status": 0, "message": ""}

    if (!IsDiscordWebhookURLWellFormed(webhookURL)) {
        result.message := "Not a URL. Paste the full webhook URL (https://discord.com/api/webhooks/...), not an ID."
        return result
    }

    payloadFile := CreateDiscordPayloadFile("PTCGPB webhook test" . (label != "" ? " (" . label . ")" : "") . " - if you can read this, the webhook works.")
    if (payloadFile = "") {
        result.message := "Could not create the test payload file."
        return result
    }

    curlCommand := GetDiscordCurlBaseCommand() . "-F ""payload_json=<" . payloadFile . ";type=application/json;charset=UTF-8"" """ . webhookURL . """"
    ; Not every script that includes Logging.ahk also includes Utils.ahk, so resolve CmdRet dynamically.
    if (IsFunc("CmdRet")) {
        cmdFn := Func("CmdRet")
        curlResult := cmdFn.Call(curlCommand)
    } else {
        RunWait, %curlCommand%,, Hide
        curlResult := "HTTP_STATUS:" . ErrorLevel
    }
    FileDelete, %payloadFile%

    status := GetDiscordCurlHttpStatus(curlResult)
    result.status := status
    result.ok := (status >= 200 && status < 300)

    if (result.ok)
        result.message := "OK"
    else if (status = 401 || status = 403 || status = 404)
        result.message := "Discord rejected the webhook (HTTP " . status . "). It was deleted or the URL is incomplete - copy it again from Discord."
    else if (status = 429)
        result.message := "Rate limited by Discord (HTTP 429). Wait a moment and try again."
    else if (status = 0 && InStr(curlResult, "Could not resolve host"))
        result.message := "Could not resolve the host name. Check the URL and your internet/DNS connection."
    else if (status = 0)
        result.message := "No response: " . TrimDiscordCurlResult(StrReplace(curlResult, "HTTP_STATUS:000"))
    else
        result.message := "Unexpected response (HTTP " . status . ")."

    if (result.ok && !IsDiscordWebhookURL(webhookURL))
        result.message .= " (note: this does not look like a discord.com webhook URL)"

    LogToFile("Discord webhook test | label=" . label . " | status=" . status . " | webhook=" . RedactDiscordWebhookURL(webhookURL) . " | result=" . TrimDiscordCurlResult(curlResult), "Discord.txt")
    return result
}

CreateDiscordTraceId() {
    static sequence := 0
    sequence++
    return A_Now . "_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . "_" . sequence
}

CreateDiscordPayloadFile(content) {
    payloadJson := "{""content"":""" . DiscordEscapeJson(content) . """}"
    payloadFile := A_Temp . "\ptcgpb_discord_payload_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . ".json"

    FileDelete, %payloadFile%
    FileAppend, %payloadJson%, %payloadFile%, UTF-8-RAW
    if (ErrorLevel || !FileExist(payloadFile))
        return ""

    return payloadFile
}

DiscordEscapeJson(text) {
    text := StrReplace(text, "\n", "`n")
    text := StrReplace(text, Chr(92), Chr(92) . Chr(92))
    text := StrReplace(text, Chr(34), Chr(92) . Chr(34))
    text := StrReplace(text, "`r", "")
    text := StrReplace(text, "`n", Chr(92) . "n")
    text := StrReplace(text, "`t", Chr(92) . "t")
    return text
}

GetDiscordCurlHttpStatus(curlResult) {
    if RegExMatch(curlResult, "HTTP_STATUS:(\d{3})", match)
        return match1 + 0
    return 0
}

TrimDiscordCurlResult(curlResult) {
    curlResult := StrReplace(curlResult, "`r", " ")
    curlResult := StrReplace(curlResult, "`n", " ")
    curlResult := Trim(curlResult)

    if (StrLen(curlResult) > 500)
        curlResult := SubStr(curlResult, 1, 500) . "..."

    return curlResult
}

RedactDiscordWebhookURL(webhookURL) {
    return RegExReplace(webhookURL, "i)(/api/webhooks/[^/\s]+/)[^?\s]+", "$1<redacted>")
}

FormatDiscordException(e) {
    if (IsObject(e)) {
        if (e.Message != "")
            return e.Message
        if (e.What != "")
            return e.What
    }
    return e
}
