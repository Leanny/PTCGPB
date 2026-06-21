#NoEnv
#SingleInstance Force
SetBatchLines, -1
SetTitleMatchMode, 2
SendMode Input
SetWorkingDir %A_ScriptDir%

getScriptBaseFolder() {
    return A_ScriptDir . "\.."
}

#Include %A_ScriptDir%\..\Scripts\Include\AccountMetadata.ahk

global XM_Root := getScriptBaseFolder()
global XM_SavedDir := XM_Root . "\Accounts\Saved"
global XM_JsonDir := XM_Root . "\Accounts\Cards\accounts"
global XM_SortedDir := XM_Root . "\Accounts\Sorted"
global XM_LastPlan := ""
global XM_LastAction := ""
global XM_LastTemplate := ""
global XM_LastFilter := 0
global XM_LastMinPacks := 0
global XM_LastMaxPacks := 0
global XM_ShowPullReport := false
global XM_PullFilterOptions := "Last pull beyond 24 hours|Last pull within 24 hours|No last pull recorded"

if (!FileExist(XM_JsonDir)) {
    MsgBox, 16, XML Account Manager, Metadata folder not found:`n%XM_JsonDir%
    ExitApp
}

XM_BuildGui()
XM_RefreshSummary()
return

XM_BuildGui() {
    global
    bg := "161A1D"
    bg2 := "20262B"
    inputBg := "2A2F35"
    text := "E7ECEF"
    muted := "95A1A8"
    accent := "4CC9F0"
    border := "2A3136"

    Gui, Destroy
    Gui, +Resize +MinSize1000x720
    Gui, Color, %bg%, %bg2%
    Gui, Margin, 22, 18

    Gui, Font, s15 c%text%, Segoe UI
    Gui, Add, Text, x24 y18 w360 h32, XML Account Manager
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x520 y28 w456 h20 Right, Manage saved accounts safely.
    Gui, Add, Progress, x24 y62 w952 h2 c%accent% Background%border% Disabled, 100

    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Tab3, x24 y82 w952 h360 vMainTab gMainTabChanged, Overview|Batch Rename|Separate/Copy

    Gui, Tab, 1
    Gui, Font, s11 c%text%, Segoe UI
    Gui, Add, Text, x54 y120 w250 h24, Account Library
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x54 y146 w420 h20, Current JSON metadata and matching XML files in Saved.
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Button, x690 y124 w120 h30 gLastPullReport, Last pull report
    Gui, Add, Button, x822 y124 w120 h30 gScanNow, Refresh scan
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x54 y178 w147 h18 Center, JSON accounts
    Gui, Add, Text, x201 y178 w147 h18 Center, XML in Saved
    Gui, Add, Text, x348 y178 w147 h18 Center, Missing XML
    Gui, Add, Text, x495 y178 w147 h18 Center, 96+ packs
    Gui, Add, Text, x642 y178 w147 h18 Center, 0-13 packs
    Gui, Add, Text, x789 y178 w147 h18 Center, 14-95 packs
    Gui, Font, s18 c%text%, Segoe UI
    Gui, Add, Text, x54 y200 w147 h34 Center vMetricJson, -
    Gui, Add, Text, x201 y200 w147 h34 Center vMetricXml, -
    Gui, Add, Text, x348 y200 w147 h34 Center vMetricMissing, -
    Gui, Add, Text, x495 y200 w147 h34 Center vMetricReady, -
    Gui, Add, Text, x642 y200 w147 h34 Center vMetricLow, -
    Gui, Add, Text, x789 y200 w147 h34 Center vMetricMid, -
    Gui, Add, Progress, x54 y248 w886 h1 c%border% Background%border% Disabled, 100
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, GroupBox, x54 y262 w250 h148 c%muted%, Pack ranges
    Gui, Add, GroupBox, x346 y262 w250 h148 c%muted%, Languages
    Gui, Add, GroupBox, x638 y262 w302 h148 c%muted%, Instances
    Gui, Font, s9 c%text%, Segoe UI
    Gui, Add, Text, x74 y292 w126 h96 vPackBreakdownLabels, Refresh scan.
    Gui, Add, Text, x205 y292 w70 h96 Right vPackBreakdownValues,
    Gui, Add, Text, x366 y292 w166 h96 vLanguageBreakdownLabels, Refresh scan.
    Gui, Add, Text, x535 y292 w40 h96 Right vLanguageBreakdownValues,
    Gui, Add, Text, x658 y292 w78 h96 vInstanceLeftLabels, Refresh scan.
    Gui, Add, Text, x738 y292 w45 h96 Right vInstanceLeftValues,
    Gui, Add, Text, x804 y292 w78 h96 vInstanceRightLabels,
    Gui, Add, Text, x884 y292 w45 h96 Right vInstanceRightValues,

    Gui, Tab, 2
    Gui, Font, s12 c%text%, Segoe UI
    Gui, Add, Text, x54 y124 w260 h28, Batch Rename XMLs
    Gui, Font, s10 c%muted%, Segoe UI
    Gui, Add, Text, x54 y154 w700 h24, Rename XML files and update their JSON metadata fileName references.
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Text, x54 y198 w100 h24, Rename style
    Gui, Add, DropDownList, x170 y194 w360 vRenameStyle AltSubmit Choose1 gRenameStyleChanged Background%inputBg% c%text%, Standard pack archive|Pack archive by language|Name + friend code|Name + packs + friend code|Language + name + packs|Device ID|Device ID + packs|Instance + device ID|Custom template
    Gui, Add, Text, x54 y238 w100 h24, Template
    Gui, Add, Edit, x170 y234 w650 h26 vRenameTemplate hwndXM_RenameTemplateHwnd Disabled Background%inputBg% c%text%, {packCount}P_{createdAt}_{instance}.xml
    Gui, Add, Button, x838 y232 w80 h30 gResetTemplate, Reset
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x54 y274 w100 h24, Fields
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x170 y270 w720 h52, {packCount}=packs   {createdAt}=created   {instance}=bot   {language}=language`n{accountName}=name   {friendCode}=friend code   {deviceAccount}=account ID   {lastPackPulled}=last pull
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Button, x170 y314 w140 h32 gPreviewRename, Preview rename
    Gui, Add, Button, x326 y314 w140 h32 gApplyRename, Apply rename

    Gui, Tab, 3
    Gui, Font, s12 c%text%, Segoe UI
    Gui, Add, Text, x54 y124 w300 h28, Separate/Copy XMLs
    Gui, Font, s10 c%muted%, Segoe UI
    Gui, Add, Text, x54 y154 w500 h24, Copy accounts for export, or move them fully out of active bot folders.
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Text, x54 y198 w100 h24, Selection
    Gui, Add, DropDownList, x170 y194 w360 vSortFilter AltSubmit Choose3 gSortFilterChanged Background%inputBg% c%text%, 0-13 packs|14-95 packs|96+ packs|Missing XML or JSON pair|Claim completed|Receive gift completed|Language Japanese|Language English|Language French|Language Italian|Language German|Language Spanish|Language Portuguese|Language Traditional Chinese|Language Korean|Custom pack range|%XM_PullFilterOptions%
    Gui, Add, Text, x54 y238 w100 h24 vRangeLabel, Pack range
    Gui, Add, Edit, x170 y234 w70 h26 Number vMinPacks Center Disabled Background%inputBg% c%text%, 96
    Gui, Add, Text, x252 y238 w24 h24 vRangeToLabel, to
    Gui, Add, Edit, x286 y234 w70 h26 Number vMaxPacks Center Disabled Background%inputBg% c%text%, 999
    Gui, Add, Text, x170 y238 w190 h24 vRangeHint c%muted%, Preset range is fixed
    Gui, Add, Text, x390 y238 w210 h24 c%muted%, JSON included automatically
    Gui, Add, Text, x54 y278 w100 h24, XML output
    Gui, Add, Text, x170 y278 w650 h24 c%accent%, Accounts\Sorted\{group}\XML
    Gui, Add, Text, x54 y304 w100 h24, JSON output
    Gui, Add, Text, x170 y304 w650 h24 c%accent%, Accounts\Sorted\{group}\JSON
    Gui, Font, s12 c%text%, Segoe UI
    Gui, Add, Text, x610 y124 w250 h28, Actions
    Gui, Add, Progress, x610 y154 w300 h1 c%border% Background%border% Disabled, 100
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Text, x610 y184 w150 h20, Preview
    Gui, Add, Button, x780 y178 w130 h30 gPreviewSort, Preview
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x610 y205 w150 h18, Check selection
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Text, x610 y246 w150 h20, Copy
    Gui, Add, Button, x780 y240 w130 h30 gApplySort, Copy accounts
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x610 y267 w150 h18, Keep Saved
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Text, x610 y308 w150 h20, Move
    Gui, Add, Button, x780 y302 w130 h30 gMoveSort, Move accounts
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x610 y329 w150 h18, Remove from Saved

    Gui, Tab
    Gui, Font, s11 c%text%, Segoe UI
    Gui, Add, Text, x24 y466 w250 h26 vPreviewTitle, Preview/Results
    Gui, Font, s9 c%muted%, Segoe UI
    Gui, Add, Text, x720 y472 w255 h20 Right vPreviewHint, Preview is read-only.
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Edit, x24 y498 w952 h148 vLogBox ReadOnly -Wrap +VScroll Background%inputBg% c%text%, Ready.
    Gui, Font, s10 c%text%, Segoe UI
    Gui, Add, Text, x204 y654 w592 h18 Center vProgressText, Ready.
    Gui, Add, Progress, x204 y674 w592 h12 vActionProgress Range0-100 c%accent% Background%border%, 0
    Gui, Add, Button, x804 y664 w80 h32 gClearLog, Clear
    Gui, Add, Button, x896 y664 w80 h32 gCloseGui, Close

    Gui, Show, w1000 h715, XML Account Manager
    XM_SetTemplateReadOnly(true)
    XM_UpdateSortRangeControls()
    XM_UpdatePreviewVisibility()
}

MainTabChanged:
    Gui, Submit, NoHide
    XM_ShowPullReport := false
    XM_UpdatePreviewVisibility()
return

ScanNow:
    XM_RefreshSummary()
return

LastPullReport:
    XM_ShowLastPullReport()
return

RenameStyleChanged:
    XM_SetTemplateFromStyle()
return

ResetTemplate:
    XM_SetTemplateFromStyle(true)
return

SortFilterChanged:
    Gui, Submit, NoHide
    XM_UpdateSortRangeControls()
return

PreviewRename:
    Gui, Submit, NoHide
    GuiControlGet, template,, RenameTemplate
    XM_LastAction := "rename"
    XM_LastTemplate := template
    XM_LastPlan := XM_BuildRenamePlan(template)
    XM_SetLog(XM_LastPlan.Text)
return

ApplyRename:
    Gui, Submit, NoHide
    GuiControlGet, template,, RenameTemplate
    if (template = "") {
        MsgBox, 48, XML Account Manager, Choose a rename template first.
        return
    }
    plan := XM_BuildRenamePlan(template)
    if (plan.Count = 0) {
        XM_SetLog(plan.Text)
        MsgBox, 64, XML Account Manager, Nothing to rename.
        return
    }
    MsgBox, 4, Confirm Rename, % "Rename " . plan.Count . " XML file(s)?`n`nThe matching JSON metadata will be updated."
    IfMsgBox No
        return
    result := XM_ExecuteRenamePlan(plan)
    XM_RefreshSummary(false)
    XM_SetLog(result)
return

PreviewSort:
    Gui, Submit, NoHide
    if (!XM_ValidateSortInputs())
        return
    XM_LastAction := "sort"
    XM_LastFilter := SortFilter
    XM_LastMinPacks := MinPacks + 0
    XM_LastMaxPacks := MaxPacks + 0
    XM_LastPlan := XM_BuildCopyPlan(SortFilter, XM_LastMinPacks, XM_LastMaxPacks)
    XM_SetLog(XM_LastPlan.Text)
return

ApplySort:
    Gui, Submit, NoHide
    if (!XM_ValidateSortInputs())
        return
    plan := XM_BuildCopyPlan(SortFilter, MinPacks + 0, MaxPacks + 0)
    if (plan.Count = 0) {
        XM_SetLog(plan.Text)
        MsgBox, 64, XML Account Manager, Nothing to copy.
        return
    }
    MsgBox, 4, Confirm Copy, % "Copy " . plan.Count . " XML file(s) to Accounts\Sorted?`n`nOriginal files will remain in Saved."
    IfMsgBox No
        return
    result := XM_ExecuteCopyPlan(plan)
    XM_RefreshSummary(false)
    XM_SetLog(result)
return

MoveSort:
    Gui, Submit, NoHide
    if (!XM_ValidateSortInputs())
        return
    plan := XM_BuildCopyPlan(SortFilter, MinPacks + 0, MaxPacks + 0)
    if (plan.Count = 0) {
        XM_SetLog(plan.Text)
        MsgBox, 64, XML Account Manager, Nothing to move.
        return
    }
    MsgBox, 4, Confirm Move, % "Move " . plan.Count . " account(s) to Accounts\Sorted?`n`nThis removes XMLs from Saved and moves their JSON metadata out of Cards\accounts."
    IfMsgBox No
        return
    result := XM_ExecuteMovePlan(plan)
    XM_RefreshSummary(false)
    XM_SetLog(result)
return

ClearLog:
    GuiControlGet, tab,, MainTab
    XM_ShowPullReport := false
    if (tab = "Overview") {
        GuiControl,, PackBreakdownLabels, Refresh scan.
        GuiControl,, PackBreakdownValues,
        GuiControl,, LanguageBreakdownLabels, Refresh scan.
        GuiControl,, LanguageBreakdownValues,
        GuiControl,, InstanceLeftLabels, Refresh scan.
        GuiControl,, InstanceLeftValues,
        GuiControl,, InstanceRightLabels, Refresh scan.
        GuiControl,, InstanceRightValues,
        XM_UpdatePreviewVisibility()
    } else {
        XM_SetLog("Ready.")
    }
    XM_ProgressReset()
return

CloseGui:
GuiClose:
ExitApp
return

XM_SetTemplateFromStyle(resetCustom := false) {
    GuiControlGet, style,, RenameStyle
    style += 0

    if (style = 1)
        template := "{packCount}P_{createdAt}_{instance}.xml"
    else if (style = 2)
        template := "{packCount}P_{language}_{createdAt}_{instance}.xml"
    else if (style = 3)
        template := "{accountName}({friendCode}).xml"
    else if (style = 4)
        template := "{accountName}_{packCount}P({friendCode}).xml"
    else if (style = 5)
        template := "{language}_{accountName}_{packCount}P.xml"
    else if (style = 6)
        template := "{deviceAccount}.xml"
    else if (style = 7)
        template := "{deviceAccount}_{packCount}P.xml"
    else if (style = 8)
        template := "{instance}_{deviceAccount}.xml"
    else {
        XM_SetTemplateReadOnly(false)
        if (resetCustom) {
            template := "{packCount}P_{createdAt}_{instance}.xml"
            GuiControl,, RenameTemplate, %template%
        }
        GuiControl, Focus, RenameTemplate
        return
    }
    GuiControl,, RenameTemplate, %template%
    XM_SetTemplateReadOnly(true)
}

XM_SetTemplateReadOnly(readOnly) {
    global XM_RenameTemplateHwnd
    option := readOnly ? "Disable" : "Enable"
    GuiControl, %option%, RenameTemplate
    if (XM_RenameTemplateHwnd)
        DllCall("SendMessage", "Ptr", XM_RenameTemplateHwnd, "UInt", 0xCF, "Ptr", 0, "Ptr", 0)
}

XM_UpdateSortRangeControls() {
    GuiControlGet, filter,, SortFilter
    filter += 0
    packRange := (filter = 16)
    packOption := packRange ? "Enable" : "Disable"
    GuiControl, %packOption%, MinPacks
    GuiControl, %packOption%, MaxPacks

    if (packRange) {
        GuiControl, Show, RangeLabel
        GuiControl, Show, MinPacks
        GuiControl, Show, RangeToLabel
        GuiControl, Show, MaxPacks
        GuiControl, Hide, RangeHint
    } else {
        GuiControl, Hide, RangeLabel
        GuiControl, Hide, MinPacks
        GuiControl, Hide, RangeToLabel
        GuiControl, Hide, MaxPacks
        if (filter >= 1 && filter <= 15)
            GuiControl, Show, RangeHint
        else
            GuiControl, Hide, RangeHint
    }
}

XM_ValidateSortInputs() {
    GuiControlGet, filter,, SortFilter
    filter += 0
    if (filter = 16)
        return XM_ValidateRange(MinPacks, MaxPacks)
    return true
}

XM_UpdatePreviewVisibility() {
    global XM_ShowPullReport
    GuiControlGet, tab,, MainTab
    hidePreview := (tab = "Overview" && !XM_ShowPullReport)
    previewOption := hidePreview ? "Hide" : "Show"
    tabHeight := hidePreview ? 360 : 300
    GuiControl, Move, MainTab, h%tabHeight%

    if (!hidePreview) {
        GuiControl, Move, PreviewTitle, y406
        GuiControl, Move, PreviewHint, x720 y412
        GuiControl, Move, LogBox, y438 h208
    }

    GuiControl, %previewOption%, PreviewTitle
    GuiControl, %previewOption%, PreviewHint
    GuiControl, %previewOption%, LogBox
}

XM_RefreshSummary(updateLog := true) {
    XM_ProgressStart("Scanning account library...")
    accounts := XM_LoadAccounts("Reading JSON metadata")
    xmlTotal := XM_CountXmlFiles("Counting XML files")
    missing := 0
    ready96 := 0
    p1_13 := 0
    p14_95 := 0
    totalAccounts := accounts.Length()

    for idx, account in accounts {
        XM_ProgressUpdate(idx, totalAccounts, "Matching XML files")
        if (XM_ResolveXml(account) = "")
            missing++
        packs := account.PackCount + 0
        if (packs >= 0 && packs <= 13)
            p1_13++
        else if (packs >= 14 && packs <= 95)
            p14_95++
        if (packs >= 96)
            ready96++
    }

    text := "JSON accounts: " . accounts.Length() . "    XML in Saved: " . xmlTotal . "`n"
    text .= "Missing XML: " . missing . "`n"
    text .= "0-13: " . p1_13 . "    14-95: " . p14_95 . "    96+: " . ready96
    GuiControl,, MetricJson, % accounts.Length()
    GuiControl,, MetricXml, %xmlTotal%
    GuiControl,, MetricMissing, %missing%
    GuiControl,, MetricReady, %ready96%
    GuiControl,, MetricLow, %p1_13%
    GuiControl,, MetricMid, %p14_95%
    XM_SetOverviewBreakdown(accounts)
    summaryDetails := XM_BuildPackSummary(accounts, missing, xmlTotal)
    if (updateLog) {
        GuiControlGet, tab,, MainTab
        if (tab != "Overview")
            XM_SetLog(summaryDetails)
    }
    XM_ProgressDone("Scan complete.")
}

XM_SetLog(text) {
    GuiControl,, LogBox, %text%
}

XM_AssembleReportText(header, summary, listText := "") {
    text := header
    if (summary != "")
        text .= summary
    if (listText != "")
        text .= listText
    return text
}

XM_ProgressStart(label) {
    GuiControl,, ProgressText, %label%
    GuiControl,, ActionProgress, 0
}

XM_ProgressUpdate(current, total, label := "") {
    if (total <= 0)
        return
    if (current < total && Mod(current, 25) != 0)
        return

    percent := Round((current / total) * 100)
    if (percent > 100)
        percent := 100
    if (label != "")
        GuiControl,, ProgressText, % label . " (" . current . "/" . total . ")"
    GuiControl,, ActionProgress, %percent%
    Sleep, -1
}

XM_ProgressDone(label := "Ready.") {
    GuiControl,, ActionProgress, 100
    GuiControl,, ProgressText, %label%
    Sleep, -1
}

XM_ProgressReset(label := "Ready.") {
    GuiControl,, ActionProgress, 0
    GuiControl,, ProgressText, %label%
}

XM_ValidateRange(minPacks, maxPacks) {
    minPacks += 0
    maxPacks += 0
    if (minPacks > maxPacks) {
        MsgBox, 48, XML Account Manager, Minimum packs cannot be greater than maximum packs.
        return false
    }
    return true
}

XM_LoadAccounts(progressLabel := "") {
    global XM_JsonDir
    accounts := []
    totalFiles := 0

    if (progressLabel != "") {
        Loop, Files, %XM_JsonDir%\*.json, F
            totalFiles++
    }

    Loop, Files, %XM_JsonDir%\*.json, F
    {
        if (progressLabel != "")
            XM_ProgressUpdate(A_Index, totalFiles, progressLabel)

        SplitPath, A_LoopFileName,,, ext, deviceAccount
        if (deviceAccount = "")
            continue

        account := AccountMetadata_ReadAccountUnlocked(deviceAccount)
        fileName := account["fileName"]
        instance := account["instance"]
        if (fileName = "" || instance = "")
            continue

        accounts.Push({DeviceAccount: deviceAccount
            , Instance: instance
            , FileName: fileName
            , AccountName: account["accountName"]
            , FriendCode: account["friendCode"]
            , Language: account["language"]
            , PackCount: account["packCount"] + 0
            , CreatedAt: account["createdAt"]
            , LastPackPulled: account["lastPackPulled"]
            , Raw: account})
    }

    return accounts
}

XM_CountXmlFiles(progressLabel := "") {
    global XM_SavedDir
    count := 0
    Loop, Files, %XM_SavedDir%\*.xml, R
    {
        count++
        if (progressLabel != "" && Mod(count, 100) = 0) {
            GuiControl,, ProgressText, % progressLabel . " (" . count . " found)"
        }
    }
    return count
}

XM_ResolveXml(ByRef account) {
    global XM_SavedDir
    saveDir := XM_SavedDir . "\" . account.Instance
    if (!FileExist(saveDir))
        return ""

    exact := saveDir . "\" . account.FileName
    if (FileExist(exact))
        return exact

    deviceName := account.DeviceAccount . ".xml"
    devicePath := saveDir . "\" . deviceName
    if (FileExist(devicePath)) {
        account.FileName := deviceName
        return devicePath
    }

    if (account.CreatedAt != "" && account.CreatedAt != "0") {
        pattern := "*" . account.CreatedAt . "*.xml"
        matches := 0
        found := ""
        foundName := ""
        Loop, Files, %saveDir%\%pattern%, F
        {
            dev := AccountMetadata_GetDeviceAccountFromFile(A_LoopFileFullPath)
            if (dev != "" && dev != account.DeviceAccount)
                continue
            matches++
            found := A_LoopFileFullPath
            foundName := A_LoopFileName
        }
        if (matches = 1) {
            account.FileName := foundName
            return found
        }
    }

    return ""
}

XM_BuildPackSummary(accounts, missing, xmlTotal) {
    lowPacks := 0
    midPacks := 0
    highPacks := 0
    languageCounts := {}
    instanceCounts := {}

    for idx, account in accounts {
        packs := account.PackCount + 0
        if (packs >= 0 && packs <= 13)
            lowPacks++
        else if (packs >= 14 && packs <= 95)
            midPacks++
        else if (packs >= 96)
            highPacks++

        language := XM_NormalizeLanguage(account.Language)
        if (language = "")
            language := "(blank)"
        if (!languageCounts.HasKey(language))
            languageCounts[language] := 0
        languageCounts[language]++

        instance := account.Instance
        if (instance = "")
            instance := "(blank)"
        if (!instanceCounts.HasKey(instance))
            instanceCounts[instance] := 0
        instanceCounts[instance]++
    }

    packLines := []
    packLines.Push(XM_FormatColumnLine("0-13 packs", lowPacks))
    packLines.Push(XM_FormatColumnLine("14-95 packs", midPacks))
    packLines.Push(XM_FormatColumnLine("96+ packs", highPacks))

    languageLines := []
    XM_AddLanguageCount(languageLines, languageCounts, "ja", "Japanese")
    XM_AddLanguageCount(languageLines, languageCounts, "en", "English")
    XM_AddLanguageCount(languageLines, languageCounts, "fr", "French")
    XM_AddLanguageCount(languageLines, languageCounts, "it", "Italian")
    XM_AddLanguageCount(languageLines, languageCounts, "de", "German")
    XM_AddLanguageCount(languageLines, languageCounts, "es", "Spanish")
    XM_AddLanguageCount(languageLines, languageCounts, "pt", "Portuguese")
    XM_AddLanguageCount(languageLines, languageCounts, "zh", "Traditional Chinese")
    XM_AddLanguageCount(languageLines, languageCounts, "ko", "Korean")
    for language, count in languageCounts {
        if !(language = "ja" || language = "en" || language = "fr" || language = "it" || language = "de" || language = "es" || language = "pt" || language = "zh" || language = "ko")
            languageLines.Push(XM_FormatColumnLine(language, count))
    }

    instanceLines := []
    Loop, 20 {
        instance := A_Index
        if (instanceCounts.HasKey(instance))
            instanceLines.Push(XM_FormatColumnLine("Instance " . instance, instanceCounts[instance]))
    }
    for instance, count in instanceCounts {
        if !(instance >= 1 && instance <= 20)
            instanceLines.Push(XM_FormatColumnLine("Instance " . instance, count))
    }

    text := XM_PadRight("PACK RANGES", 28) . XM_PadRight("LANGUAGES", 34) . "INSTANCES`n"
    text .= XM_PadRight("-----------", 28) . XM_PadRight("---------", 34) . "---------`n"

    maxRows := packLines.Length()
    if (languageLines.Length() > maxRows)
        maxRows := languageLines.Length()
    if (instanceLines.Length() > maxRows)
        maxRows := instanceLines.Length()

    Loop, %maxRows% {
        packLine := (A_Index <= packLines.Length()) ? packLines[A_Index] : ""
        languageLine := (A_Index <= languageLines.Length()) ? languageLines[A_Index] : ""
        instanceLine := (A_Index <= instanceLines.Length()) ? instanceLines[A_Index] : ""
        text .= XM_PadRight(packLine, 28) . XM_PadRight(languageLine, 34) . instanceLine . "`n"
    }
    return text
}

XM_SetOverviewBreakdown(accounts) {
    lowPacks := 0
    midPacks := 0
    highPacks := 0
    languageCounts := {}
    instanceCounts := {}

    for idx, account in accounts {
        packs := account.PackCount + 0
        if (packs >= 0 && packs <= 13)
            lowPacks++
        else if (packs >= 14 && packs <= 95)
            midPacks++
        else if (packs >= 96)
            highPacks++

        language := XM_NormalizeLanguage(account.Language)
        if (language = "")
            language := "(blank)"
        if (!languageCounts.HasKey(language))
            languageCounts[language] := 0
        languageCounts[language]++

        instance := account.Instance
        if (instance = "")
            instance := "(blank)"
        if (!instanceCounts.HasKey(instance))
            instanceCounts[instance] := 0
        instanceCounts[instance]++
    }

    packLabels := "0-13`n14-95`n96+"
    packValues := lowPacks . "`n" . midPacks . "`n" . highPacks

    languageLabels := ""
    languageValues := ""
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "ja", "Japanese")
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "en", "English")
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "fr", "French")
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "it", "Italian")
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "de", "German")
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "es", "Spanish")
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "pt", "Portuguese")
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "zh", "Traditional Chinese")
    XM_AddOverviewLanguage(languageLabels, languageValues, languageCounts, "ko", "Korean")
    for language, count in languageCounts {
        if !(language = "ja" || language = "en" || language = "fr" || language = "it" || language = "de" || language = "es" || language = "pt" || language = "zh" || language = "ko") {
            languageLabels .= language . "`n"
            languageValues .= count . "`n"
        }
    }
    languageLabels := RTrim(languageLabels, "`n")
    languageValues := RTrim(languageValues, "`n")

    instanceLeftLabels := ""
    instanceLeftValues := ""
    instanceRightLabels := ""
    instanceRightValues := ""
    instanceIndex := 0
    Loop, 20 {
        instance := A_Index
        if (!instanceCounts.HasKey(instance))
            continue
        instanceIndex++
        if (instanceIndex <= 5) {
            instanceLeftLabels .= "Instance " . instance . "`n"
            instanceLeftValues .= instanceCounts[instance] . "`n"
        } else {
            instanceRightLabels .= "Instance " . instance . "`n"
            instanceRightValues .= instanceCounts[instance] . "`n"
        }
    }
    for instance, count in instanceCounts {
        if (instance >= 1 && instance <= 20)
            continue
        instanceIndex++
        if (instanceIndex <= 5) {
            instanceLeftLabels .= "Instance " . instance . "`n"
            instanceLeftValues .= count . "`n"
        } else {
            instanceRightLabels .= "Instance " . instance . "`n"
            instanceRightValues .= count . "`n"
        }
    }

    GuiControl,, PackBreakdownLabels, %packLabels%
    GuiControl,, PackBreakdownValues, %packValues%
    GuiControl,, LanguageBreakdownLabels, %languageLabels%
    GuiControl,, LanguageBreakdownValues, %languageValues%
    GuiControl,, InstanceLeftLabels, % RTrim(instanceLeftLabels, "`n")
    GuiControl,, InstanceLeftValues, % RTrim(instanceLeftValues, "`n")
    GuiControl,, InstanceRightLabels, % RTrim(instanceRightLabels, "`n")
    GuiControl,, InstanceRightValues, % RTrim(instanceRightValues, "`n")
}

XM_AddOverviewLanguage(ByRef labels, ByRef values, ByRef languageCounts, code, label) {
    if (!languageCounts.HasKey(code))
        return
    labels .= label . "`n"
    values .= languageCounts[code] . "`n"
}

XM_AddLanguageCount(ByRef outLines, ByRef languageCounts, code, label) {
    if (!languageCounts.HasKey(code))
        return
    outLines.Push(XM_FormatColumnLine(label . " (" . code . ")", languageCounts[code]))
}

XM_FormatColumnLine(label, value) {
    return label . ": " . value
}

XM_PadRight(value, width) {
    value := "" . value
    len := StrLen(value)
    if (len >= width)
        return SubStr(value, 1, width)
    Loop, % width - len
        value .= " "
    return value
}

XM_BuildRenamePlan(template) {
    XM_ProgressStart("Preparing rename preview...")
    accounts := XM_LoadAccounts("Reading JSON metadata")
    plan := {Items: [], Count: 0, Missing: 0, Skipped: 0, Text: ""}
    usedTargets := {}
    header := "=== Rename preview ===`n"
    header .= "Template: " . template . "`n`n"
    listText := ""
    totalAccounts := accounts.Length()

    for idx, account in accounts {
        XM_ProgressUpdate(idx, totalAccounts, "Building rename preview")
        xmlPath := XM_ResolveXml(account)
        if (xmlPath = "") {
            plan.Missing++
            continue
        }

        newName := XM_TemplateName(template, account)
        if (newName = "") {
            plan.Skipped++
            listText .= "[Skip: missing data] " . account.FileName . "`n"
            continue
        }

        if (XM_Lower(newName) = XM_Lower(account.FileName)) {
            plan.Skipped++
            continue
        }

        SplitPath, xmlPath,, xmlDir
        newName := XM_UniqueName(xmlDir, newName, usedTargets, xmlPath)
        newPath := xmlDir . "\" . newName
        key := XM_Lower(newPath)
        usedTargets[key] := true

        plan.Items.Push({Account: account, OldPath: xmlPath, NewPath: newPath, OldName: account.FileName, NewName: newName})
        plan.Count++
        listText .= account.FileName . "  ->  " . newName . "`n"
    }

    summary := "To rename: " . plan.Count . "    Skipped: " . plan.Skipped . "    Missing XML: " . plan.Missing . "`n`n"
    plan.Text := XM_AssembleReportText(header, summary, listText)
    XM_ProgressDone("Rename preview ready.")
    return plan
}

XM_TemplateName(template, account) {
    if (InStr(template, "{accountName}") && account.AccountName = "")
        return ""
    if (InStr(template, "{friendCode}") && account.FriendCode = "")
        return ""
    if (InStr(template, "{language}") && XM_NormalizeLanguage(account.Language) = "")
        return ""

    createdAt := account.CreatedAt
    if (createdAt = "" || createdAt = "0")
        createdAt := "unknown"

    lastPackPulled := XM_GetLastPackPulled(account)
    if (lastPackPulled = "")
        lastPackPulled := "unknown"

    name := template
    name := StrReplace(name, "{packCount}", account.PackCount)
    name := StrReplace(name, "{createdAt}", createdAt)
    name := StrReplace(name, "{lastPackPulled}", lastPackPulled)
    name := StrReplace(name, "{instance}", account.Instance)
    name := StrReplace(name, "{language}", XM_NormalizeLanguage(account.Language))
    name := StrReplace(name, "{accountName}", account.AccountName)
    name := StrReplace(name, "{friendCode}", account.FriendCode)
    name := StrReplace(name, "{deviceAccount}", account.DeviceAccount)
    name := RegExReplace(name, "[\\/:*?""<>|]", "_")
    name := RegExReplace(name, "\s+", " ")
    name := Trim(name)

    if (name = "" || name = ".xml")
        return ""
    if (SubStr(name, -3) != ".xml")
        name .= ".xml"
    return name
}

XM_UniqueName(dir, fileName, ByRef usedTargets, excludePath := "") {
    SplitPath, fileName,,, ext, baseName
    if (ext = "")
        ext := "xml"

    candidate := fileName
    i := 1
    while (true) {
        fullPath := dir . "\" . candidate
        key := XM_Lower(fullPath)
        exists := FileExist(fullPath)
        if (exists && excludePath != "" && XM_Lower(fullPath) = XM_Lower(excludePath))
            exists := false
        if (!exists && !usedTargets.HasKey(key))
            break
        candidate := baseName . "_" . i . "." . ext
        i++
    }
    return candidate
}

XM_ExecuteRenamePlan(plan) {
    changed := 0
    errors := 0
    header := "=== Rename results ===`n`n"
    listText := ""
    totalItems := plan.Items.Length()
    XM_ProgressStart("Renaming XML files...")

    for idx, item in plan.Items {
        XM_ProgressUpdate(idx, totalItems, "Renaming XML files")
        oldPath := item.OldPath
        newPath := item.NewPath
        FileMove, %oldPath%, %newPath%, 0
        if (ErrorLevel) {
            errors++
            listText .= "[Error] " . item.OldName . " -> " . item.NewName . "`n"
            continue
        }

        account := item.Account.Raw
        account["fileName"] := item.NewName
        account["instance"] := item.Account.Instance
        if (!AccountMetadata_WriteAccountUnlocked(item.Account.DeviceAccount, account)) {
            errors++
            listText .= "[Metadata error] " . item.NewName . "`n"
            continue
        }

        changed++
        listText .= "[OK] " . item.OldName . " -> " . item.NewName . "`n"
    }

    summary := "Renamed: " . changed . "    Errors: " . errors . "`n`n"
    XM_ProgressDone("Rename complete.")
    return XM_AssembleReportText(header, summary, listText)
}

XM_BuildCopyPlan(filter, minPacks, maxPacks) {
    global XM_SortedDir, XM_SavedDir
    XM_ProgressStart("Preparing copy preview...")
    accounts := XM_LoadAccounts("Reading JSON metadata")
    plan := {Items: [], Count: 0, Missing: 0, Skipped: 0, Text: ""}
    header := "=== Selection preview ===`n"
    header .= "Selection: " . XM_FilterName(filter, minPacks, maxPacks) . "`n`n"
    listText := ""
    totalAccounts := accounts.Length()

    if (filter = 4) {
        XM_AddIncompleteAccounts(plan, listText, accounts)
        summary := "Selected: " . plan.Count . "    Skipped: " . plan.Skipped . "    Missing XML: " . plan.Missing . "`n`n"
        plan.Text := XM_AssembleReportText(header, summary, listText)
        XM_ProgressDone("Copy preview ready.")
        return plan
    }

    for idx, account in accounts {
        XM_ProgressUpdate(idx, totalAccounts, "Building copy preview")
        group := XM_GroupForAccount(account, filter, minPacks, maxPacks)
        if (group = "") {
            plan.Skipped++
            continue
        }

        xmlPath := XM_ResolveXml(account)
        if (xmlPath = "") {
            plan.Missing++
            continue
        }

        destBaseDir := XM_SortedDir . "\" . group
        destXmlDir := destBaseDir . "\XML"
        destJsonDir := destBaseDir . "\JSON"

        destName := account.FileName
        destPath := destXmlDir . "\" . destName
        if (XM_Lower(xmlPath) = XM_Lower(destPath)) {
            plan.Skipped++
            continue
        }

        jsonSource := AccountMetadata_AccountPath(account.DeviceAccount)
        plan.Items.Push({Account: account, OldPath: xmlPath, JsonSource: jsonSource, HasXml: true, HasJson: FileExist(jsonSource) ? true : false, DestXmlDir: destXmlDir, DestJsonDir: destJsonDir, DestName: destName, DestPath: destPath, Group: group})
        plan.Count++
        listText .= account.FileName . "  ->  " . destXmlDir . "`n"
    }

    summary := "Selected: " . plan.Count . "    Skipped: " . plan.Skipped . "    Missing XML: " . plan.Missing . "`n"
    summary .= "JSON files will be included when present.`n`n"
    plan.Text := XM_AssembleReportText(header, summary, listText)
    XM_ProgressDone("Copy preview ready.")
    return plan
}

XM_AddIncompleteAccounts(ByRef plan, ByRef listText, accounts) {
    global XM_SavedDir, XM_SortedDir
    knownJson := {}

    for idx, account in accounts {
        if (account.DeviceAccount != "")
            knownJson[account.DeviceAccount] := true

        xmlPath := XM_ResolveXml(account)
        if (xmlPath != "")
            continue

        jsonSource := AccountMetadata_AccountPath(account.DeviceAccount)
        if (!FileExist(jsonSource))
            continue

        group := "incomplete_json_only"
        destBaseDir := XM_SortedDir . "\" . group
        item := {Account: account
            , OldPath: ""
            , JsonSource: jsonSource
            , HasXml: false
            , HasJson: true
            , DestXmlDir: destBaseDir . "\XML"
            , DestJsonDir: destBaseDir . "\JSON"
            , DestName: ""
            , DestPath: ""
            , Group: group}
        plan.Items.Push(item)
        plan.Count++
        listText .= account.DeviceAccount . ".json  ->  " . item.DestJsonDir . "`n"
    }

    Loop, Files, %XM_SavedDir%\*.xml, R
    {
        xmlPath := A_LoopFileFullPath
        SplitPath, xmlPath, fileName
        deviceAccount := AccountMetadata_GetDeviceAccountFromFile(xmlPath)
        if (deviceAccount != "" && knownJson.HasKey(deviceAccount))
            continue

        group := "incomplete_xml_only"
        destBaseDir := XM_SortedDir . "\" . group
        account := {DeviceAccount: deviceAccount, FileName: fileName}
        item := {Account: account
            , OldPath: xmlPath
            , JsonSource: ""
            , HasXml: true
            , HasJson: false
            , DestXmlDir: destBaseDir . "\XML"
            , DestJsonDir: destBaseDir . "\JSON"
            , DestName: fileName
            , DestPath: destBaseDir . "\XML\" . fileName
            , Group: group}
        plan.Items.Push(item)
        plan.Count++
        listText .= fileName . "  ->  " . item.DestXmlDir . "`n"
    }
}

XM_ExecuteCopyPlan(plan) {
    copied := 0
    errors := 0
    header := "=== Copy results ===`n`n"
    listText := ""
    totalItems := plan.Items.Length()
    XM_ProgressStart("Copying XML files...")

    for idx, item in plan.Items {
        XM_ProgressUpdate(idx, totalItems, "Copying XML files")

        if (item.HasXml) {
            destDir := item.DestXmlDir
            if (!FileExist(destDir))
                FileCreateDir, %destDir%

            usedTargets := {}
            destName := XM_UniqueName(destDir, item.DestName, usedTargets)
            destPath := destDir . "\" . destName
            oldPath := item.OldPath
            FileCopy, %oldPath%, %destPath%, 0
            if (ErrorLevel) {
                errors++
                listText .= "[Error] " . item.Account.FileName . "`n"
                continue
            }
        }

        if (item.HasJson) {
            jsonDir := item.DestJsonDir
            if (!FileExist(jsonDir))
                FileCreateDir, %jsonDir%
            jsonSource := item.JsonSource
            jsonDest := jsonDir . "\" . item.Account.DeviceAccount . ".json"
            if (FileExist(jsonSource))
                FileCopy, %jsonSource%, %jsonDest%, 1
        }

        copied++
        listText .= "[OK] " . item.Account.FileName . " -> " . item.Group . "`n"
    }

    summary := "Copied: " . copied . "    Errors: " . errors . "`n`n"
    XM_ProgressDone("Copy complete.")
    return XM_AssembleReportText(header, summary, listText)
}

XM_ExecuteMovePlan(plan) {
    moved := 0
    errors := 0
    header := "=== Move results ===`n`n"
    listText := ""
    totalItems := plan.Items.Length()
    XM_ProgressStart("Moving accounts...")

    for idx, item in plan.Items {
        XM_ProgressUpdate(idx, totalItems, "Moving accounts")

        xmlDir := item.DestXmlDir
        jsonDir := item.DestJsonDir
        if (item.HasXml) {
            if (!FileExist(xmlDir))
                FileCreateDir, %xmlDir%

            usedTargets := {}
            destName := XM_UniqueName(xmlDir, item.DestName, usedTargets)
            destPath := xmlDir . "\" . destName
            oldPath := item.OldPath
            FileMove, %oldPath%, %destPath%, 0
            if (ErrorLevel) {
                errors++
                listText .= "[XML Error] " . item.Account.FileName . "`n"
                continue
            }
        }

        if (item.HasJson) {
            if (!FileExist(jsonDir))
                FileCreateDir, %jsonDir%
            jsonSource := item.JsonSource
            jsonDest := jsonDir . "\" . item.Account.DeviceAccount . ".json"
            FileMove, %jsonSource%, %jsonDest%, 0
            if (ErrorLevel) {
                errors++
                listText .= "[JSON error] " . item.Account.FileName . " (XML already moved)`n"
                continue
            }
        }

        moved++
        listText .= "[OK] " . item.Account.FileName . " -> " . item.Group . "`n"
    }

    summary := "Moved: " . moved . "    Errors: " . errors . "`n`n"
    XM_ProgressDone("Move complete.")
    return XM_AssembleReportText(header, summary, listText)
}

XM_GroupForAccount(account, filter, minPacks, maxPacks) {
    packs := account.PackCount + 0
    if (filter = 1)
        return (packs >= 0 && packs <= 13) ? "packs_00-13" : ""
    if (filter = 2)
        return (packs >= 14 && packs <= 95) ? "packs_14-95" : ""
    if (filter = 3)
        return (packs >= 96) ? "packs_96plus" : ""
    if (filter = 4)
        return ""
    if (filter = 5)
        return (XM_FlagIsSet(account, "C") || XM_FlagIsSet(account, "X")) ? "flag_claim_completed" : ""
    if (filter = 6)
        return XM_FlagIsSet(account, "R") ? "flag_receive_gift_completed" : ""
    if (filter = 7)
        return (XM_NormalizeLanguage(account.Language) = "ja") ? "language_ja" : ""
    if (filter = 8)
        return (XM_NormalizeLanguage(account.Language) = "en") ? "language_en" : ""
    if (filter = 9)
        return (XM_NormalizeLanguage(account.Language) = "fr") ? "language_fr" : ""
    if (filter = 10)
        return (XM_NormalizeLanguage(account.Language) = "it") ? "language_it" : ""
    if (filter = 11)
        return (XM_NormalizeLanguage(account.Language) = "de") ? "language_de" : ""
    if (filter = 12)
        return (XM_NormalizeLanguage(account.Language) = "es") ? "language_es" : ""
    if (filter = 13)
        return (XM_NormalizeLanguage(account.Language) = "pt") ? "language_pt" : ""
    if (filter = 14)
        return (XM_NormalizeLanguage(account.Language) = "zh") ? "language_zh" : ""
    if (filter = 15)
        return (XM_NormalizeLanguage(account.Language) = "ko") ? "language_ko" : ""
    if (filter = 16)
        return (packs >= minPacks && packs <= maxPacks) ? "packs_" . minPacks . "-" . maxPacks : ""
    if (filter = 17)
        return XM_AccountMatchesPullFilter(account, 17) ? "last_pulled_24h_plus" : ""
    if (filter = 18)
        return XM_AccountMatchesPullFilter(account, 18) ? "last_pulled_24h_minus" : ""
    if (filter = 19)
        return XM_AccountMatchesPullFilter(account, 19) ? "last_pulled_never" : ""
    return ""
}

XM_FilterName(filter, minPacks, maxPacks) {
    if (filter >= 17 && filter <= 19)
        return XM_PullFilterLabel(filter)
    names := ["0-13 packs", "14-95 packs", "96+ packs", "Missing XML or JSON pair", "Claim completed", "Receive gift completed", "Language Japanese", "Language English", "Language French", "Language Italian", "Language German", "Language Spanish", "Language Portuguese", "Language Traditional Chinese", "Language Korean", "Custom " . minPacks . "-" . maxPacks . " packs"]
    return names[filter]
}

XM_PullFilterLabel(filter) {
    if (filter = 17)
        return "Last pull beyond 24 hours"
    if (filter = 18)
        return "Last pull within 24 hours"
    if (filter = 19)
        return "No last pull recorded"
    return ""
}

XM_GetLastPackPulled(account) {
    ts := account.Raw["lastPackPulled"]
    if (ts = "" || ts = "0")
        return ""
    return ts
}

XM_HoursSincePull(account) {
    ts := XM_GetLastPackPulled(account)
    if (ts = "")
        return -1
    hours := A_Now
    EnvSub, hours, %ts%, Hours
    if (hours < 0)
        hours := 0
    return hours
}

XM_AccountMatchesPullFilter(account, pullFilter) {
    if (pullFilter = 0)
        return true

    hours := XM_HoursSincePull(account)
    if (pullFilter = 17)
        return (hours >= 24)
    if (pullFilter = 18)
        return (hours >= 0 && hours < 24)
    if (pullFilter = 19)
        return (hours < 0)
    return false
}

XM_FormatPullTime(timestamp) {
    if (timestamp = "" || timestamp = "0")
        return "Never"
    return SubStr(timestamp, 1, 4) . "-" . SubStr(timestamp, 5, 2) . "-" . SubStr(timestamp, 7, 2) . " " . SubStr(timestamp, 9, 2) . ":" . SubStr(timestamp, 11, 2)
}

XM_PullSortKey(account) {
    ts := XM_GetLastPackPulled(account)
    if (ts = "")
        return 0
    return ts + 0
}

XM_SortAccountsByPull(ByRef accounts) {
    count := accounts.Length()
    if (count < 2)
        return

    Loop, % count - 1 {
        outer := A_Index
        Loop, % count - outer {
            inner := outer + A_Index
            if (XM_PullSortKey(accounts[inner]) > XM_PullSortKey(accounts[outer])) {
                temp := accounts[outer]
                accounts[outer] := accounts[inner]
                accounts[inner] := temp
            }
        }
    }
}

XM_ShowLastPullReport() {
    global XM_ShowPullReport
    XM_ProgressStart("Building last pull report...")
    accounts := XM_LoadAccounts("Reading JSON metadata")
    XM_SortAccountsByPull(accounts)

    neverCount := 0
    within24 := 0
    older24 := 0
    header := "=== Last pull report ===`n"
    header .= "Sorted by most recent pull first. Times come from JSON lastPackPulled.`n`n"
    listText := XM_PadRight("File name", 34) . XM_PadRight("Inst", 6) . XM_PadRight("Packs", 7) . "Last pulled`n"
    listText .= XM_PadRight("---------", 34) . XM_PadRight("----", 6) . XM_PadRight("-----", 7) . "-----------`n"

    totalAccounts := accounts.Length()
    for idx, account in accounts {
        XM_ProgressUpdate(idx, totalAccounts, "Building last pull report")
        ts := XM_GetLastPackPulled(account)
        hours := XM_HoursSincePull(account)
        if (hours < 0)
            neverCount++
        else if (hours < 24)
            within24++
        else
            older24++

        fileLabel := account.FileName
        if (StrLen(fileLabel) > 32)
            fileLabel := SubStr(fileLabel, 1, 29) . "..."
        listText .= XM_PadRight(fileLabel, 34) . XM_PadRight(account.Instance, 6) . XM_PadRight(account.PackCount, 7) . XM_FormatPullTime(ts) . "`n"
    }

    summary := "Total: " . accounts.Length() . "    Never pulled: " . neverCount . "    Within 24h: " . within24 . "    24h+ ago: " . older24 . "`n`n"
    XM_ShowPullReport := true
    XM_UpdatePreviewVisibility()
    XM_SetLog(XM_AssembleReportText(header, summary, listText))
    XM_ProgressDone("Last pull report ready.")
}

XM_FlagIsSet(account, flag) {
    flags := account.Raw["flags"]
    return IsObject(flags) && flags.HasKey(flag) && flags[flag]["value"]
}

XM_NormalizeLanguage(language) {
    language := Trim(language)
    StringLower, out, language
    return out
}

XM_Lower(value) {
    StringLower, out, value
    return out
}
