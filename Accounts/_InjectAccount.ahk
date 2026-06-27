#SingleInstance on
;SetKeyDelay, -1, -1
SetMouseDelay, -1
SetDefaultMouseSpeed, 0
;SetWinDelay, -1
;SetControlDelay, -1
SetBatchLines, -1
SetTitleMatchMode, 3

global adbShell, adbPath, adbPorts, winTitle, folderPath, selectedFilePath, mumuFolder, headless, injectInProgress

IniRead, winTitle, InjectAccount.ini, UserSettings, winTitle, 1
IniRead, fileName, InjectAccount.ini, UserSettings, fileName, name
IniRead, selectedFilePath, InjectAccount.ini, UserSettings, selectedFilePath, ""
IniRead, sendFriendRequestAfterInject, InjectAccount.ini, UserSettings, sendFriendRequestAfterInject, 0
IniRead, favoriteFriendIDsIni, InjectAccount.ini, UserSettings, favoriteFriendIDs,
if (favoriteFriendIDsIni = "ERROR")
    favoriteFriendIDsIni := ""
IniRead, favoriteFriendLabelsIni, InjectAccount.ini, UserSettings, favoriteFriendLabels,
if (favoriteFriendLabelsIni = "ERROR")
    favoriteFriendLabelsIni := ""
IniRead, injectSelectedFriendIDsIni, InjectAccount.ini, UserSettings, injectSelectedFriendIDs,
if (injectSelectedFriendIDsIni = "ERROR")
    injectSelectedFriendIDsIni := ""
IniRead, injectExtraFriendIDsIni, InjectAccount.ini, UserSettings, injectExtraFriendIDs,
if (injectExtraFriendIDsIni = "ERROR")
    injectExtraFriendIDsIni := ""
if (favoriteFriendIDsIni = "" && injectExtraFriendIDsIni != "") {
    favoriteFriendIDsIni := injectExtraFriendIDsIni
    if (injectSelectedFriendIDsIni = "")
        injectSelectedFriendIDsIni := injectExtraFriendIDsIni
}

settingsIniFriend := A_ScriptDir . "\..\Settings.ini"
IniRead, folderPath, %settingsIniFriend%, ToolsAndSystem, folderPath, C:\Program Files\Netease

favPick1 := 0
favPick2 := 0
favPick3 := 0
favPick4 := 0
favPick5 := 0
favPick6 := 0
favPick7 := 0
favPick8 := 0
favPick9 := 0
favPick10 := 0
favId1 := ""
favId2 := ""
favId3 := ""
favId4 := ""
favId5 := ""
favId6 := ""
favId7 := ""
favId8 := ""
favId9 := ""
favId10 := ""
favLabel1 := ""
favLabel2 := ""
favLabel3 := ""
favLabel4 := ""
favLabel5 := ""
favLabel6 := ""
favLabel7 := ""
favLabel8 := ""
favLabel9 := ""
favLabel10 := ""
LoadInjectFavoriteGuiState(favoriteFriendIDsIni, favoriteFriendLabelsIni, injectSelectedFriendIDsIni)

; --- Headless mode (called from the Card Dashboard HTML server) ---------
headless := false
Loop, %0%
{
    arg := %A_Index%
    if (arg = "/headless" || arg = "--headless" || arg = "-headless")
    {
        headless := true
        break
    }
}

if (headless)
{
    Gosub, RunInjectFlow
    ExitApp
}
; -------------------------------------------------------------------------

; Set a custom font and size for better appearance
Gui, Destroy
Gui, Font, s10, Segoe UI
Gui, Color, 1E1E1E  ; Dark background color
Gui, Font, cDCDCDC  ; Light text color

; Add a title with warning styling
Gui, Add, Text, x10 y10 w450 cWhite, This tool is to INJECT (login to) the selected account.
Gui, Add, Text, x10 y+5 w450 cRed, It will LOG OUT OF any current account in that instance.
Gui, Add, Text, x10 y+5 w450 cWhite, Ensure you have the login info of the current account (either a .xml file, nintendo account link, etc.) or you will LOSE it.

; Create a horizontal line for visual separation
Gui, Add, Text, x10 y+15 w450 h1 0x10 c3F3F3F ; Darker separator

; Instance section
instanceList := GetInstanceList(folderPath)
selectedIndex := 1
if (instanceList != "") {
    StringSplit, arr, instanceList, |
    Loop, %arr0%
    {
        if (arr%A_Index% = winTitle) {
            selectedIndex := A_Index
            break
        }
    }
}
Gui, Add, Text, x10 y+15 w450, Instance Name:
Gui, Add, DropDownList, x10 y+5 vwinTitle w340 Choose%selectedIndex%, %instanceList%
Gui, Add, Button, x+10 yp w100 gRefreshInstances, Refresh

; File section
Gui, Add, Text, x10 y+15 w450 cDCDCDC, File Name (without spaces and without .xml):
Gui, Add, Edit, x10 y+5 vfileName w340 c000000 BackgroundFFFFFF, %fileName%
Gui, Add, Button, x+10 yp w100 gBrowseFile, Browse

; Folder section
Gui, Add, Text, x10 y+15 w450 cDCDCDC, MuMu Folder same as main script (C:\Program Files\Netease)
Gui, Add, Edit, x10 y+5 vfolderPath w450 c000000 BackgroundFFFFFF, %folderPath%

; Friend request options — 2 columns aligned to MuMu folder field (x10 + w450)
friendCheckText := "Send friend request(s) after inject"
sendFriendCheckOpt := sendFriendRequestAfterInject ? "Checked" : ""
Gui, Add, Checkbox, x10 y+12 vsendFriendRequestAfterInject %sendFriendCheckOpt% cDCDCDC, %friendCheckText%
Gui, Add, Text, x10 y+8 w450 cGray, Friends (saved). Check to send on this inject (max 10):
favGridX := 10
favGridW := 450
favGridRight := favGridX + favGridW
favColGap := 16
favColW := (favGridW - favColGap) // 2
favC1EndX := favGridX + favColW
favEditH := 22
favChkH := 13
favChkW := 13
favChkYOffset := (favEditH - favChkH) // 2
favNameOff := 16
favNameW := 71
favFieldGap := 4
favC1ChkX := favGridX
favC1NameX := favGridX + favNameOff
favC1IdX := favC1NameX + favNameW + favFieldGap
favC1IdW := favC1EndX - favC1IdX
favC2ChkX := favC1EndX + favColGap
favC2NameX := favC2ChkX + favNameOff
favC2IdX := favC2NameX + favNameW + favFieldGap
favC2IdW := favGridRight - favC2IdX
Gui, Font, s8 cGray
Gui, Add, Text, x%favC1NameX% y+4 w%favNameW% Center, Name
Gui, Add, Text, x%favC1IdX% yp w%favC1IdW% Center, Friend ID
Gui, Add, Text, x%favC2NameX% yp w%favNameW% Center, Name
Gui, Add, Text, x%favC2IdX% yp w%favC2IdW% Center, Friend ID
Gui, Font, s10 cDCDCDC
Loop, 5 {
    leftIdx := A_Index
    rightIdx := A_Index + 5
    labelVarL := "favLabel" . leftIdx
    idVarL := "favId" . leftIdx
    labelVarR := "favLabel" . rightIdx
    idVarR := "favId" . rightIdx
    pickVarL := "favPick" . leftIdx
    pickVarR := "favPick" . rightIdx
    pickOptL := %pickVarL% ? "Checked" : ""
    pickOptR := %pickVarR% ? "Checked" : ""
    ctrlLabelL := "FavLabel" . leftIdx
    ctrlIdL := "FavId" . leftIdx
    ctrlPickL := "FavPick" . leftIdx
    ctrlLabelR := "FavLabel" . rightIdx
    ctrlIdR := "FavId" . rightIdx
    ctrlPickR := "FavPick" . rightIdx
    labelValL := %labelVarL%
    idValL := %idVarL%
    labelValR := %labelVarR%
    idValR := %idVarR%
    Gui, Add, Edit, x%favC1NameX% y+4 w%favNameW% h%favEditH% v%ctrlLabelL% c000000 BackgroundFFFFFF, %labelValL%
    Gui, Add, Checkbox, x%favC1ChkX% yp+%favChkYOffset% w%favChkW% h%favChkH% v%ctrlPickL% %pickOptL% cDCDCDC
    Gui, Add, Edit, x%favC1IdX% yp-%favChkYOffset% w%favC1IdW% h%favEditH% v%ctrlIdL% Number Limit16 c000000 BackgroundFFFFFF, %idValL%
    Gui, Add, Edit, x%favC2NameX% yp w%favNameW% h%favEditH% v%ctrlLabelR% c000000 BackgroundFFFFFF, %labelValR%
    Gui, Add, Checkbox, x%favC2ChkX% yp+%favChkYOffset% w%favChkW% h%favChkH% v%ctrlPickR% %pickOptR% cDCDCDC
    Gui, Add, Edit, x%favC2IdX% yp-%favChkYOffset% w%favC2IdW% h%favEditH% v%ctrlIdR% Number Limit16 c000000 BackgroundFFFFFF, %idValR%
}

Gui, Add, Text, x10 y+8 w450 h1 0x10 c3F3F3F

Gui, Add, Text, x10 y+6 w450 vInjectStatusText c8FD18A, Ready.
Gui, Add, Progress, x10 y+4 w450 h8 vInjectProgress c4AAE3A Background303030, 0
Gui, Add, Button, x130 y+8 w100 h40 vSubmitBtn gSaveSettings cBlue, Submit
Gui, Add, Button, x+10 yp w100 h40 vRunInstanceBtn gRunInstance cGreen, Run Instance

Gui, Show, w470 AutoSize, Arturo's Account Injection Tool ;'
ApplyInjectFriendEditPlaceholders()
Return

SetEditCueBanner(hwnd, bannerText) {
    static EM_SETCUEBANNER := 0x1501
    if (!hwnd)
        return
    DllCall("SendMessageW", "Ptr", hwnd, "UInt", EM_SETCUEBANNER, "Ptr", 1, "WStr", bannerText)
}

RegisterInjectFriendPlaceholder(ctrlName, placeholderText, currentValue) {
    if (Trim(currentValue) != "")
        return
    GuiControlGet, hwnd, Hwnd, %ctrlName%
    SetEditCueBanner(hwnd, placeholderText)
}

NormalizeInjectFriendEditValue(val, placeholder) {
    val := Trim(val)
    if (val = "" || val = placeholder)
        return ""
    return val
}

ApplyInjectFriendEditPlaceholders() {
    Loop, 10 {
        ctrlLabel := "FavLabel" . A_Index
        ctrlId := "FavId" . A_Index
        GuiControlGet, labelVal, , %ctrlLabel%
        GuiControlGet, idVal, , %ctrlId%
        RegisterInjectFriendPlaceholder(ctrlLabel, "Name", labelVal)
        RegisterInjectFriendPlaceholder(ctrlId, "16-digit Friend ID", idVal)
    }
}

OnGuiClose:
ExitApp

GuiClose:
ExitApp

BrowseFile:
    FileSelectFile, selectedFile, 3, , Select XML File, XML Files (*.xml)
    if (selectedFile != "")
    {
        SplitPath, selectedFile, fileNameNoExt, , , fileNameNoExtNoPath
        GuiControl,, fileName, %fileNameNoExtNoPath%
        selectedFilePath := selectedFile
    }
return

SaveSettings:
    if (injectInProgress)
        return
    Gui, Submit, NoHide
    if (!ValidateInjectFavoriteFriends())
        return
    if (sendFriendRequestAfterInject) {
        resolvedN := FriendRequestResolvedCount(InjectSelectedFriendIdsToCsv())
        if (resolvedN < 1) {
            MsgBox, 48, Friends, Send friend requests is enabled but no friends are checked.`n`nCheck at least one friend to send.
            return
        }
        if (resolvedN > 10) {
            MsgBox, 48, Friends, Maximum 10 friends per inject.`n`nYou have: %resolvedN%.
            return
        }
    }
    injectInProgress := 1
    SetInjectUiBusy(true)
    UpdateInjectUi("Saving settings...", 5)
    SaveInjectFriendIniSettings()
; fall through into RunInjectFlow

RunInjectFlow:
    UpdateInjectUi("Resolving MuMu folder...", 10)
    mumuFolder := getMumuFolder(folderPath)

    UpdateInjectUi("Locating ADB and instance port...", 18)
    adbPath := mumuFolder . "\shell\adb.exe"
    if !FileExist(adbPath)
        adbPath := mumuFolder . "\nx_main\adb.exe"
    findAdbPorts(mumuFolder)

    if(!WinExist(winTitle)) {
        Msgbox, 16, , Can't find instance: %winTitle%. Make sure that instance is running.'
        UpdateInjectUi("Selected instance is not running.", 0)
        SetInjectUiBusy(false)
        injectInProgress := 0
        return
    }

    if !FileExist(adbPath) ;if international mumu file path isn't found look for chinese domestic path
        adbPath := folderPath . "\MuMu Player 12\shell\adb.exe"
    if !FileExist(adbPath)
        adbPath := folderPath . "\MuMuPlayer-12.0\shell\adb.exe"
    if !FileExist(adbPath) ;MuMu Player 12 v5
        adbPath := folderPath . "\MuMuPlayerGlobal-12.0\nx_main\adb.exe"
    if !FileExist(adbPath) ;MuMu Player 12 v5
        adbPath := folderPath . "\MuMu Player 12\nx_main\adb.exe"
    if !FileExist(adbPath)
        adbPath := folderPath . "\MuMuPlayer-12.0\nx_main\adb.exe"
    if !FileExist(adbPath) ;MuMu Player 12 v5
        adbPath := folderPath . "\MuMuPlayer\nx_main\adb.exe"
    if !FileExist(adbPath)
        adbPath := folderPath . "\MuMuPlayer-12\shell\adb.exe"
    if !FileExist(adbPath)
        adbPath := folderPath . "\MuMuPlayer-12\nx_main\adb.exe"
    if !FileExist(adbPath)
        adbPath := folderPath . "\MuMuPlayer12\shell\adb.exe"
    if !FileExist(adbPath)
        adbPath := folderPath . "\MuMuPlayer12\nx_main\adb.exe"

    if !FileExist(adbPath) {
        MsgBox, 16, , Double check your folder path! It should be the one that contains the MuMuPlayer 12 folder! `nDefault is just C:\Program Files\Netease
        UpdateInjectUi("Invalid MuMu folder path.", 0)
        SetInjectUiBusy(false)
        injectInProgress := 0
        return
    }

    if(!adbPorts) {
        Msgbox, 16, , Invalid port... Check the common issues section in the readme/github guide.
        UpdateInjectUi("Could not resolve ADB port.", 0)
        SetInjectUiBusy(false)
        injectInProgress := 0
        return
    }

    filePath := selectedFilePath
    if (filePath = "")
        filePath := A_ScriptDir . "\" . fileName . ".xml"

    if(!FileExist(filePath)) {
        Msgbox, 16, , Can't find XML file: %filePath% ;'
        UpdateInjectUi("XML file not found.", 0)
        SetInjectUiBusy(false)
        injectInProgress := 0
        return
    }
    UpdateInjectUi("Connecting to emulator...", 30)
    RunWait, %adbPath% connect 127.0.0.1:%adbPorts%,, Hide
    if (ErrorLevel != 0) {
        MsgBox, 16, , Failed to connect ADB on port %adbPorts%.
        UpdateInjectUi("Connection failed.", 0)
        SetInjectUiBusy(false)
        injectInProgress := 0
        return
    }
    RunWait, %adbPath% -s 127.0.0.1:%adbPorts% root,, Hide

    UpdateInjectUi("Injecting account data...", 45)
    if !loadAccount() {
        UpdateInjectUi("Inject failed.", 0)
        SetInjectUiBusy(false)
        injectInProgress := 0
        return
    }
    UpdateInjectUi("Account injected.", 85)

    ; Optional: send a friend request to the account whose code is set in
    ; Settings.ini ([General] FriendID). The worker script reuses the bot's
    ; image-search + ADB primitives (same as 1.ahk) and runs a focused
    ; friend-request flow only.
    if (sendFriendRequestAfterInject) {
        UpdateInjectUi("Sending friend request(s)...", 92)
        resolvedList := BuildResolvedFriendRequestList(InjectSelectedFriendIdsToCsv())
        IniWrite, %resolvedList%, InjectAccount.ini, UserSettings, injectFriendRequestIds
        sendFRScript := A_ScriptDir . "\_SendFriendRequest.ahk"
        if (FileExist(sendFRScript)) {
            RunWait, %A_AhkPath% "%sendFRScript%" "%winTitle%" "%folderPath%"
        } else {
            MsgBox, 48, , Cannot find _SendFriendRequest.ahk next to _InjectAccount.ahk.
        }
    }
    UpdateInjectUi("Done.", 100)
    SetInjectUiBusy(false)
    injectInProgress := 0
return

getMumuFolder(folderPath) {
    candidateFolders := [folderPath
        , folderPath . "\MuMu"
        , folderPath . "\MuMuPlayerGlobal-12.0"
        , folderPath . "\MuMuPlayerGlobal"
        , folderPath . "\MuMuPlayer-12.0"
        , folderPath . "\MuMu Player 12"
        , folderPath . "\MuMuPlayer"
        , folderPath . "\MuMuPlayer-12"
        , folderPath . "\MuMuPlayer12"]

    for _, candidateFolder in candidateFolders {
        if FileExist(candidateFolder . "\nx_main")
            return candidateFolder
    }

    return folderPath . "\MuMuPlayerGlobal-12.0"
}

GetVmDisplayName(folder) {
    configFolder := folder "\configs"
    extraConfigFile := configFolder "\extra_config.json"

    if FileExist(extraConfigFile) {
        FileRead, fileContent, %extraConfigFile%
        RegExMatch(fileContent, """playerName"":\s*""(.*?)""", playerName)
        if (playerName1 != "")
            return playerName1
    }

    SplitPath, folder, folderName
    return folderName
}

findAdbPorts(mumuFolderParam) {
    global adbPorts, winTitle
    ; Initialize variables
    adbPorts := 0  ; Create an empty associative array for adbPorts
    mumuFolderPath = %mumuFolderParam%\vms\*
    if !FileExist(mumuFolderPath){
        MsgBox, 16, , Double check your folder path! It should be the one that contains the MuMuPlayer 12 folder! `nDefault is just C:\Program Files\Netease
        return
    }
    ; Loop through all directories in the base folder
    Loop, Files, %mumuFolderPath%, D  ; D flag to include directories only
    {
        folder := A_LoopFileFullPath
        configFolder := folder "\configs"  ; The config folder inside each directory
        displayName := GetVmDisplayName(folder)

        ; Check if config folder exists
        IfExist, %configFolder%
        {
            ; Define paths to vm_config.json and extra_config.json
            vmConfigFile := configFolder "\vm_config.json"
            extraConfigFile := configFolder "\extra_config.json"

            ; Check if vm_config.json exists and read adb host port
            IfExist, %vmConfigFile%
            {
                FileRead, vmConfigContent, %vmConfigFile%
                ; Parse the JSON for adb host port
                RegExMatch(vmConfigContent, """host_port"":\s*""(\d+)""", adbHostPort)
                adbPort := adbHostPort1  ; Capture the adb host port value
            }

            ; Check if extra_config.json exists and read playerName
            IfExist, %extraConfigFile%
            {
                FileRead, extraConfigContent, %extraConfigFile%
                ; Parse the JSON for playerName
                RegExMatch(extraConfigContent, """playerName"":\s*""(.*?)""", playerName)
                if(playerName1 = winTitle || displayName = winTitle) {
                    adbPorts := adbPort
                }
            }
            else if (displayName = winTitle) {
                adbPorts := adbPort
            }
        }
    }
}

RunAdbRootCommand(shellCommand) {
    global adbPath, adbPorts
    q := Chr(34)
    sq := Chr(39)
    device := "127.0.0.1:" . adbPorts

    ; Prefer adb root shell. Nested su/sh -c hangs on MuMu Android 15.
    rootShellCommand := q . adbPath . q . " -s " . device . " shell " . sq . shellCommand . sq
    RunWait, %rootShellCommand%,, Hide
    if (ErrorLevel = 0)
        return 1

    suCommand := q . adbPath . q . " -s " . device . " shell su -c " . sq . shellCommand . sq
    RunWait, %suCommand%,, Hide
    if (ErrorLevel = 0)
        return 1

    nonRootCommand := q . adbPath . q . " -s " . device . " shell " . q . shellCommand . q
    RunWait, %nonRootCommand%,, Hide
    return (ErrorLevel = 0)
}

RunAdbPush(localPath, remotePath) {
    global adbPath, adbPorts
    pushCommand := Chr(34) . adbPath . Chr(34) . " -s 127.0.0.1:" . adbPorts . " push " . Chr(34) . localPath . Chr(34) . " " . remotePath
    RunWait, %pushCommand%,, Hide
    return (ErrorLevel = 0)
}

ShowInjectStepError(stepName) {
    MsgBox, 16, , Inject failed at step:`n%stepName%
}

SetInjectUiBusy(isBusy) {
    global headless
    if (headless)
        return

    if (isBusy) {
        GuiControl, Disable, SubmitBtn
        GuiControl, Disable, RunInstanceBtn
    } else {
        GuiControl, Enable, SubmitBtn
        GuiControl, Enable, RunInstanceBtn
    }
}

UpdateInjectUi(statusText, progressValue := "") {
    global headless
    if (headless)
        return

    GuiControl,, InjectStatusText, %statusText%
    if (progressValue != "")
        GuiControl,, InjectProgress, %progressValue%
    Sleep, 10
}

loadAccount() {
    global adbShell, adbPath, adbPorts, fileName, selectedFilePath

    static UserPreferencesPath := "/data/data/jp.pokemon.pokemontcgp/files/UserPreferences/v1/"
    static UserPreferences := ["BattleUserPrefs"
        ,"FeedUserPrefs"
        ,"FilterConditionUserPrefs"
        ,"HomeBattleMenuUserPrefs"
        ,"MissionUserPrefs"
        ,"NotificationUserPrefs"
        ,"PackUserPrefs"
        ,"PvPBattleResumeUserPrefs"
        ,"RankMatchPvEResumeUserPrefs"
        ,"RankMatchUserPrefs"
        ,"SoloBattleResumeUserPrefs"
        ,"SortConditionUserPrefs"]

    UpdateInjectUi("Stopping app...", 50)
    if !RunAdbRootCommand("am force-stop jp.pokemon.pokemontcgp") {
        ShowInjectStepError("am force-stop")
        return 0
    }
    Sleep, 200

    ; Clear app data to ensure no previous account information remains
    UpdateInjectUi("Clearing old account...", 58)
    if !RunAdbRootCommand("rm -f /data/data/jp.pokemon.pokemontcgp/shared_prefs/deviceAccount:.xml") {
        ShowInjectStepError("remove deviceAccount xml")
        return 0
    }
    Sleep, 200

    Loop, % UserPreferences.MaxIndex() {
        if !RunAdbRootCommand("rm -f " . UserPreferencesPath . UserPreferences[A_Index]) {
            ShowInjectStepError("clear user preferences")
            return 0
        }
        Sleep, 200
    }

    loadDir := selectedFilePath
    if (loadDir = "")
        loadDir := A_ScriptDir . "\" . fileName . ".xml"
    else {
        ; Don't append .xml if the path already ends with it
        SplitPath, loadDir, , , fileExt
        if (fileExt != "xml")
            loadDir := loadDir . ".xml"
    }

    ; Make sure the file exists before trying to push it
    if (!FileExist(loadDir)) {
        MsgBox, 16, Error, Cannot find the XML file: %loadDir%
        return 0
    }

    ; Push the file to the device with better error handling
    UpdateInjectUi("Uploading XML...", 68)
    if !RunAdbPush(loadDir, "/sdcard/deviceAccount.xml") {
        ShowInjectStepError("push deviceAccount xml")
        return 0
    }
    Sleep, 150

    ; Create the shared_prefs directory if it doesn't exist
    UpdateInjectUi("Applying account on device...", 74)
    if !RunAdbRootCommand("mkdir -p /data/data/jp.pokemon.pokemontcgp/shared_prefs") {
        ShowInjectStepError("create shared_prefs")
        return 0
    }
    Sleep, 100

    ; Copy the file with proper permissions
    if !RunAdbRootCommand("cp /sdcard/deviceAccount.xml /data/data/jp.pokemon.pokemontcgp/shared_prefs/deviceAccount:.xml") {
        ShowInjectStepError("copy deviceAccount xml")
        return 0
    }
    Sleep, 100

    ; Set proper permissions and ownership (combined commands with shorter delay)
    if !RunAdbRootCommand("chmod 664 /data/data/jp.pokemon.pokemontcgp/shared_prefs/deviceAccount:.xml && chown system:system /data/data/jp.pokemon.pokemontcgp/shared_prefs/deviceAccount:.xml") {
        ShowInjectStepError("chmod/chown deviceAccount xml")
        return 0
    }
    Sleep, 200

    ; Clean up and launch app (reduced delay between operations)
    if !RunAdbRootCommand("rm -f /sdcard/deviceAccount.xml") {
        ShowInjectStepError("cleanup temp xml")
        return 0
    }

    ; Launch the app with both commands in quick succession
    UpdateInjectUi("Launching game...", 80)
    if !RunAdbRootCommand("am start -n jp.pokemon.pokemontcgp/jp.pokemon.pokemontcgp.UnityPlayerActivity") {
        ShowInjectStepError("start UnityPlayerActivity")
        return 0
    }
    Sleep, 100

    if !RunAdbRootCommand("am start -n jp.pokemon.pokemontcgp/com.unity3d.player.UnityPlayerActivity") {
        ShowInjectStepError("start com.unity3d.player.UnityPlayerActivity")
        return 0
    }

    return 1
}

; New function to get instance list
GetInstanceList(baseFolder) {
    instanceList := ""
    mumuFolder := getMumuFolder(baseFolder)

    ; Loop through all VM directories
    Loop, Files, %mumuFolder%\vms\*, D
    {
        folder := A_LoopFileFullPath
        displayName := GetVmDisplayName(folder)

        if (displayName != "") {
            if (instanceList != "")
                instanceList .= "|"
            instanceList .= displayName
        }
    }

    return instanceList
}

FriendListHasId(list, id) {
    if (!IsObject(list) || !list.MaxIndex())
        return false
    Loop, % list.MaxIndex()
    {
        if (list[A_Index] = id)
            return true
    }
    return false
}

injectFriendSlotsToCsv() {
    return FavoriteFriendIdsToCsv()
}

ValidateInjectFriendSlots() {
    return ValidateInjectFavoriteFriends()
}

SaveInjectFriendIniSettings() {
    global winTitle, fileName, folderPath, selectedFilePath, sendFriendRequestAfterInject, settingsIniFriend
    IniWrite, %winTitle%, InjectAccount.ini, UserSettings, winTitle
    IniWrite, %fileName%, InjectAccount.ini, UserSettings, fileName
    IniWrite, %folderPath%, %settingsIniFriend%, ToolsAndSystem, folderPath
    IniWrite, %selectedFilePath%, InjectAccount.ini, UserSettings, selectedFilePath
    IniWrite, %sendFriendRequestAfterInject%, InjectAccount.ini, UserSettings, sendFriendRequestAfterInject
    favoriteCsv := FavoriteFriendIdsToCsv()
    labelsPipe := FavoriteFriendLabelsToPipe()
    selectedCsv := InjectSelectedFriendIdsToCsv()
    resolvedList := BuildResolvedFriendRequestList(selectedCsv)
    IniWrite, %favoriteCsv%, InjectAccount.ini, UserSettings, favoriteFriendIDs
    IniWrite, %labelsPipe%, InjectAccount.ini, UserSettings, favoriteFriendLabels
    IniWrite, %selectedCsv%, InjectAccount.ini, UserSettings, injectSelectedFriendIDs
    IniWrite, %selectedCsv%, InjectAccount.ini, UserSettings, injectExtraFriendIDs
    IniWrite, %resolvedList%, InjectAccount.ini, UserSettings, injectFriendRequestIds
}

LoadInjectFavoriteGuiState(favoriteIdsCsv, favoriteLabelsPipe, selectedIdsCsv) {
    global favPick1, favPick2, favPick3, favPick4, favPick5, favPick6, favPick7, favPick8, favPick9, favPick10
    global favId1, favId2, favId3, favId4, favId5, favId6, favId7, favId8, favId9, favId10
    global favLabel1, favLabel2, favLabel3, favLabel4, favLabel5, favLabel6, favLabel7, favLabel8, favLabel9, favLabel10

    ids := ParseInjectFriendCsvToArray(favoriteIdsCsv)
    labels := ParseInjectFriendLabelsPipe(favoriteLabelsPipe)
    selected := ParseInjectFriendCsvToArray(selectedIdsCsv)
    selectedHasAny := selected.MaxIndex() ? true : false

    Loop, 10 {
        id := ids[A_Index] ? ids[A_Index] : ""
        label := labels[A_Index] ? labels[A_Index] : ""
        idVar := "favId" . A_Index
        labelVar := "favLabel" . A_Index
        pickVar := "favPick" . A_Index
        %idVar% := id
        %labelVar% := label
        pick := 0
        if (id != "") {
            if (!selectedHasAny || FriendListHasId(selected, id))
                pick := 1
        }
        %pickVar% := pick
    }
}

ParseInjectFriendCsvToArray(rawCsv) {
    arr := []
    cleaned := RegExReplace(rawCsv, "[\r\n]+", ",")
    cleaned := RegExReplace(cleaned, "\|+", ",")
    cleaned := RegExReplace(cleaned, "[\t; ]+", ",")
    Loop {
        if (!InStr(cleaned, ",,"))
            break
        StringReplace, cleaned, cleaned, `,,`,, All
    }
    cleaned := Trim(cleaned, " `t,")
    Loop, Parse, cleaned, `,
    {
        id := Trim(A_LoopField)
        if (id = "")
            continue
        arr.Push(id)
    }
    return arr
}

ParseInjectFriendLabelsPipe(rawPipe) {
    arr := []
    Loop, Parse, rawPipe, |
    {
        arr.Push(Trim(A_LoopField))
    }
    return arr
}

FavoriteFriendIdsToCsv() {
    global favId1, favId2, favId3, favId4, favId5, favId6, favId7, favId8, favId9, favId10
    arr := [Trim(favId1), Trim(favId2), Trim(favId3), Trim(favId4), Trim(favId5), Trim(favId6), Trim(favId7), Trim(favId8), Trim(favId9), Trim(favId10)]
    out := ""
    Loop % arr.MaxIndex() {
        val := NormalizeInjectFriendEditValue(arr[A_Index], "16-digit Friend ID")
        if (val = "")
            continue
        if (out != "")
            out .= ","
        out .= val
    }
    return out
}

FavoriteFriendLabelsToPipe() {
    global favLabel1, favLabel2, favLabel3, favLabel4, favLabel5, favLabel6, favLabel7, favLabel8, favLabel9, favLabel10
    global favId1, favId2, favId3, favId4, favId5, favId6, favId7, favId8, favId9, favId10
    labels := [Trim(favLabel1), Trim(favLabel2), Trim(favLabel3), Trim(favLabel4), Trim(favLabel5), Trim(favLabel6), Trim(favLabel7), Trim(favLabel8), Trim(favLabel9), Trim(favLabel10)]
    ids := [Trim(favId1), Trim(favId2), Trim(favId3), Trim(favId4), Trim(favId5), Trim(favId6), Trim(favId7), Trim(favId8), Trim(favId9), Trim(favId10)]
    out := ""
    Loop % ids.MaxIndex() {
        id := NormalizeInjectFriendEditValue(ids[A_Index], "16-digit Friend ID")
        if (id = "")
            continue
        label := NormalizeInjectFriendEditValue(labels[A_Index], "Name")
        label := StrReplace(label, "|", " ")
        if (out != "")
            out .= "|"
        out .= label
    }
    return out
}

InjectSelectedFriendIdsToCsv() {
    global FavPick1, FavPick2, FavPick3, FavPick4, FavPick5, FavPick6, FavPick7, FavPick8, FavPick9, FavPick10
    global FavId1, FavId2, FavId3, FavId4, FavId5, FavId6, FavId7, FavId8, FavId9, FavId10
    out := ""
    Loop, 10 {
        pickVar := "FavPick" . A_Index
        idVar := "FavId" . A_Index
        if (!%pickVar%)
            continue
        id := NormalizeInjectFriendEditValue(Trim(%idVar%), "16-digit Friend ID")
        if (id = "")
            continue
        if (out != "")
            out .= ","
        out .= id
    }
    return out
}

ValidateInjectFavoriteFriends() {
    global FavId1, FavId2, FavId3, FavId4, FavId5, FavId6, FavId7, FavId8, FavId9, FavId10
    Loop, 10 {
        idVar := "FavId" . A_Index
        v := NormalizeInjectFriendEditValue(Trim(%idVar%), "16-digit Friend ID")
        if (v = "")
            continue
        if (!RegExMatch(v, "^\d{16}$")) {
            MsgBox, 48, Friends, Friend row %A_Index% must contain exactly 16 digits (numbers only).
            return false
        }
    }
    return true
}

BuildResolvedFriendRequestList(selectedCsv) {
    list := []
    cleaned := RegExReplace(selectedCsv, "[\r\n]+", ",")
    cleaned := RegExReplace(cleaned, "\|+", ",")
    cleaned := RegExReplace(cleaned, "[\t; ]+", ",")
    Loop {
        if (!InStr(cleaned, ",,"))
            break
        StringReplace, cleaned, cleaned, `,,`,, All
    }
    cleaned := Trim(cleaned, " `t,")
    Loop, Parse, cleaned, `,
    {
        id := Trim(A_LoopField)
        if (!RegExMatch(id, "^\d{16}$"))
            continue
        if (!FriendListHasId(list, id))
            list.Push(id)
    }
    out := ""
    maxN := list.MaxIndex() ? list.MaxIndex() : 0
    if (maxN > 10)
        maxN := 10
    Loop, %maxN% {
        if (out != "")
            out .= ","
        out .= list[A_Index]
    }
    return out
}

FriendRequestResolvedCount(selectedCsv) {
    resolved := BuildResolvedFriendRequestList(selectedCsv)
    if (resolved = "")
        return 0
    list := ParseInjectFriendCsvToArray(resolved)
    return list.MaxIndex() ? list.MaxIndex() : 0
}

; Refresh button handler
RefreshInstances:
    refreshedList := GetInstanceList(folderPath)
    GuiControl,, winTitle, |%refreshedList%
return

RunInstance:
    if (injectInProgress)
        return
    injectInProgress := 1
    SetInjectUiBusy(true)
    UpdateInjectUi("Starting selected instance...", 12)
    Gui, Submit, NoHide
    if (!ValidateInjectFavoriteFriends()) {
        SetInjectUiBusy(false)
        injectInProgress := 0
        return
    }
    SaveInjectFriendIniSettings()
    mumuFolder := getMumuFolder(folderPath)
    ; Find the instance number matching the selected name
    instanceNum := ""
    Loop, Files, %mumuFolder%\vms\*, D
    {
        folder := A_LoopFileFullPath
        displayName := GetVmDisplayName(folder)
        if (displayName = winTitle) {
            RegExMatch(folder, "[^-]+$", instanceNum)
            break
        }
    }
    if (instanceNum != "") {
        mumuExe := mumuFolder . "\shell\MuMuPlayer.exe"
        if !FileExist(mumuExe)
            mumuExe := mumuFolder . "\nx_main\MuMuNxMain.exe"
        if FileExist(mumuExe) {
            Run, "%mumuExe%" -v "%instanceNum%"
            UpdateInjectUi("Instance launch command sent.", 100)
        } else {
            MsgBox, 16, Error, Could not find MuMuPlayer.exe at %mumuExe%
            UpdateInjectUi("Could not find MuMu executable.", 0)
        }
    }
    else {
        MsgBox, 16, Error, Could not find instance number for %winTitle%
        UpdateInjectUi("Selected instance not found in folder.", 0)
    }
    SetInjectUiBusy(false)
    injectInProgress := 0
return
