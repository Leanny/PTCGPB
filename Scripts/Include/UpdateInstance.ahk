#SingleInstance, force
#NoEnv
SetBatchLines, -1

;-------------------------------------------------------------------------------
; UpdateInstance.ahk - Standalone tool to manage MuMu instances
;   - lists all existing MuMu instances and starts/stops them
;   - adds a new empty instance, applies the default settings for its Android version
;     and installs an apk from the apks folder
;   - updates the apk on running instances (apks come from the apks folder)
;-------------------------------------------------------------------------------

#Include %A_ScriptDir%\Config.ahk
#Include %A_ScriptDir%\Profiler.ahk
#Include %A_ScriptDir%\MumuHelper.ahk
#Include %A_ScriptDir%\Utils.ahk

global botConfig := new BotConfig()
botConfig.loadSettingsToConfig("ALL")

; Folder holding the apks to install: <repo>\apks
SplitPath, A_ScriptDir, , scriptsDir
SplitPath, scriptsDir, , repoDir
global apkFolder := repoDir . "\apks"
FileCreateDir, %apkFolder%

; Set while the apks folder holds no apk; the GUI is disabled meanwhile.
global apksMissing := false

; The game whose installed version is shown; cached per instance index as {version, tick}.
global gamePackage := "jp.pokemon.pokemontcgp"
global appVersions := {}
global versionCacheMs := 30000

if (getMuMuFolder() = "")
    ExitApp

BuildMainGui()
RefreshInstanceList()
return

;-------------------------------------------------------------------------------
; GUI
;-------------------------------------------------------------------------------

BuildMainGui() {
    global InstanceList, ToggleButton, UpdateApkButton, RefreshButton, AddButton
    Gui, Main:New, , MuMu Instance Manager
    Gui, Main:Add, ListView, vInstanceList gOnListEvent w520 h300 Grid NoSortHdr, Index|Name|Android Version|Status|App Version
    Gui, Main:Add, Button, vToggleButton gOnToggleInstance Disabled w120, Start
    Gui, Main:Add, Button, vRefreshButton gOnRefresh x+10 w120, Refresh
    Gui, Main:Add, Button, vAddButton gOnAddInstance x+10 w120, Add Instance
    Gui, Main:Add, Button, vUpdateApkButton gOnUpdateApk Disabled x+10 w120, Update APK
    Gui, Main:Add, StatusBar
    Gui, Main:Show
    SetTimer, OnRefresh, 5000
}

MainGuiClose:
MainGuiEscape:
ExitApp
return

OnRefresh:
    RefreshInstanceList()
return

OnListEvent:
    if (A_GuiEvent = "I" || A_GuiEvent = "Normal")
        UpdateToggleButton()
return

OnToggleInstance:
    ToggleSelectedInstance()
return

OnUpdateApk:
    updateTargets := GetSelectedInstances()
    apkList := GetApks()
    if (updateTargets.Length() = 0 || apkList.Length() = 0)
        return
    targetNames := ""
    for _, target in updateTargets
        targetNames .= (targetNames = "" ? "" : ", ") . target.name
    Gui, Upd:New, +OwnerMain +ToolWindow, Update APK
    Gui, Upd:Add, Text, w260, % "Update the APK on " . updateTargets.Length() . " instance(s) (data is kept):`n" . targetNames
    Gui, Upd:Add, DropDownList, vUpdApk Choose1 AltSubmit w260, % ApkDropDownItems(apkList)
    Gui, Upd:Add, Button, gOnUpdateConfirm Default w120, Update
    Gui, Upd:Add, Button, gUpdGuiClose x+20 w120, Cancel
    Gui, Main:+Disabled
    Gui, Upd:Show
return

UpdGuiClose:
UpdGuiEscape:
    Gui, Main:-Disabled
    Gui, Upd:Destroy
    Gui, Main:Show
return

OnUpdateConfirm:
    Gui, Upd:Submit, NoHide
    updateApkPath := apkList[UpdApk]
    Gui, Main:-Disabled
    Gui, Upd:Destroy
    Gui, Main:Show
    UpdateApks(updateTargets, updateApkPath)
return

OnAddInstance:
    apkList := GetApks()
    if (apkList.Length() = 0)
        return
    Gui, Add:New, +OwnerMain +ToolWindow, Add Instance
    Gui, Add:Add, Text, , Android version:
    Gui, Add:Add, DropDownList, vAddBase Choose1 w260, Android 12|Android 15
    Gui, Add:Add, Text, , APK to install:
    Gui, Add:Add, DropDownList, vAddApk Choose1 AltSubmit w260, % ApkDropDownItems(apkList)
    Gui, Add:Add, Text, , New instance name:
    Gui, Add:Add, Edit, vAddName w260, % SuggestInstanceName(GetInstances())
    Gui, Add:Add, Button, gOnAddConfirm Default w120, Create
    Gui, Add:Add, Button, gAddGuiClose x+20 w120, Cancel
    Gui, Main:+Disabled
    Gui, Add:Show
return

AddGuiClose:
AddGuiEscape:
    Gui, Main:-Disabled
    Gui, Add:Destroy
    Gui, Main:Show
return

OnAddConfirm:
    Gui, Add:Submit, NoHide
    newName := Trim(AddName)
    androidMajor := RegExReplace(AddBase, "\D")
    addApkPath := apkList[AddApk]
    Gui, Main:-Disabled
    Gui, Add:Destroy
    Gui, Main:Show
    if (newName = "") {
        MsgBox, 48, Add Instance, Please enter a name for the new instance.
        return
    }
    AddInstance(androidMajor, newName, addApkPath)
return

;-------------------------------------------------------------------------------
; MuMu operations
;-------------------------------------------------------------------------------

; Returns an array of {index, name, android, running, processStarted} objects, sorted by index.
GetInstances() {
    instances := []
    output := MuMuManagerCommand("info -v all", true)
    if (output = "")
        return instances

    pos := 1
    while (foundPos := RegExMatch(output, "s)""([^""]+)""\s*:\s*\{(.*?)\}", match, pos)) {
        body := match2
        instance := {}
        instance.index := match1
        instance.name := MuMuJsonStringValue(body, "name")
        instance.android := MuMuJsonStringValue(body, "android_version")
        instance.running := RegExMatch(body, """is_android_started""\s*:\s*true") ? true : false
        instance.processStarted := RegExMatch(body, """is_process_started""\s*:\s*true") ? true : false
        instances.Push(instance)
        pos := foundPos + StrLen(match)
    }

    ; Info is keyed alphabetically ("10" before "2"), so sort numerically.
    sorted := []
    for _, instance in instances {
        i := sorted.MaxIndex() ? sorted.MaxIndex() : 0
        while (i >= 1 && sorted[i].index + 0 > instance.index + 0)
            i--
        sorted.InsertAt(i + 1, instance)
    }
    return sorted
}

; Returns the installed game version of a running instance ("" if unknown). Cached
; for versionCacheMs so the periodic refresh doesn't query every instance each time.
GetAppVersion(index) {
    if (appVersions.HasKey(index) && A_TickCount - appVersions[index].tick < versionCacheMs)
        return appVersions[index].version
    output := MuMuManagerCommand("control -v " . MuMuQuoteArg(index) . " app info -i " . gamePackage, true)
    version := ""
    if (RegExMatch(output, "s)""" . gamePackage . """\s*:\s*\{[^}]*""version""\s*:\s*""([^""]*)""", match))
        version := match1
    appVersions[index] := {version: version, tick: A_TickCount}
    return version
}

RefreshInstanceList() {
    CheckApkFolder()
    instances := GetInstances()
    Gui, Main:Default
    selected := {}
    for _, target in GetSelectedInstances()
        selected[target.index] := true
    GuiControl, Main:-Redraw, InstanceList
    LV_Delete()
    for _, instance in instances {
        status := instance.running ? "Running" : (instance.processStarted ? "Starting" : "Stopped")
        version := instance.running ? GetAppVersion(instance.index) : ""
        LV_Add(selected.HasKey(instance.index) ? "Select" : "", instance.index, instance.name, instance.android, status, version)
    }
    ; Column 1 (index) stays in the list for lookups but is not shown; the others fit
    ; their content and header.
    LV_ModifyCol(1, 0)
    Loop, 4
        LV_ModifyCol(A_Index + 1, "AutoHdr")
    GuiControl, Main:+Redraw, InstanceList
    SB_SetText(instances.Length() . " instance(s)")
    UpdateToggleButton()
}

; Returns the selected list rows as an array of {index, name, status} objects.
GetSelectedInstances() {
    Gui, Main:Default
    targets := []
    row := 0
    while (row := LV_GetNext(row)) {
        LV_GetText(index, row, 1)
        LV_GetText(name, row, 2)
        LV_GetText(status, row, 4)
        targets.Push({index: index, name: name, status: status})
    }
    return targets
}

; Start/Stop applies to the whole selection when all selected instances are stopped
; (Start) or none is (Stop); a mixed selection disables it. Update APK needs every
; selected instance to be running (booted).
UpdateToggleButton() {
    global apksMissing
    Gui, Main:Default
    if (apksMissing)
        return
    targets := GetSelectedInstances()
    stopped := 0
    running := 0
    for _, target in targets {
        if (target.status = "Stopped")
            stopped++
        if (target.status = "Running")
            running++
    }

    if (targets.Length() = 0 || (stopped > 0 && stopped < targets.Length()))
        GuiControl, Main:Disable, ToggleButton
    else
        GuiControl, Main:Enable, ToggleButton
    GuiControl, Main:, ToggleButton, % (stopped > 0 ? "Start" : "Stop")

    if (targets.Length() > 0 && running = targets.Length())
        GuiControl, Main:Enable, UpdateApkButton
    else
        GuiControl, Main:Disable, UpdateApkButton
}

ToggleSelectedInstance() {
    targets := GetSelectedInstances()
    for _, target in targets {
        if (target.status = "Stopped") {
            SB_SetText("Starting """ . target.name . """...")
            MuMuManagerCommand("control launch -v " . MuMuQuoteArg(target.index))
        } else {
            SB_SetText("Stopping """ . target.name . """...")
            MuMuManagerCommand("control shutdown -v " . MuMuQuoteArg(target.index))
        }
    }
    RefreshInstanceList()
}

; Suggests the lowest unused positive integer as a name.
SuggestInstanceName(instances) {
    used := {}
    for _, instance in instances
        used[instance.name] := true
    n := 1
    while (used.HasKey(n . ""))
        n++
    return n . ""
}

; Default settings for new instances, taken from the reference instances for each
; Android version. Per-instance values (name, imei) and the host specific network
; bridge adapter are intentionally left out.
GetDefaultSettings(androidMajor) {
    a12 := {}
    a12["apk_asscciation"] := "true"
    a12["app_keptlive"] := "false"
    a12["dynamic_adjust_frame_rate"] := "false"
    a12["dynamic_low_frame_rate_limit"] := "30"
    a12["force_discrete_graphics"] := "true"
    a12["gpu_mode"] := "middle"
    a12["gpu_model.custom"] := "Adreno (TM) 640"
    a12["joystick_auto_connect"] := "false"
    a12["max_frame_rate"] := "30"
    a12["mini_disk"] := "false"
    a12["mouse_style"] := "true"
    a12["net_bridge_dns1"] := ""
    a12["net_bridge_dns2"] := ""
    a12["net_bridge_gateway"] := ""
    a12["net_bridge_ip_addr"] := ""
    a12["net_bridge_ip_mode"] := "dhcp"
    a12["net_bridge_open"] := "false"
    a12["net_bridge_subnet_mask"] := ""
    a12["performance_cpu.custom"] := "2"
    a12["performance_mem.custom"] := "2.000000"
    a12["performance_mode"] := "custom"
    a12["phone_brand"] := "Samsung"
    a12["phone_miit"] := "SM-F731B"
    a12["phone_model"] := "Galaxy Z Flip5"
    a12["phone_number"] := ""
    a12["quit_confirm"] := "false"
    a12["renderer_mode"] := "vk"
    a12["renderer_strategy"] := "auto"
    a12["resolution_dpi.custom"] := "220.000000"
    a12["resolution_height.custom"] := "960.000000"
    a12["resolution_mode"] := "custom"
    a12["resolution_width.custom"] := "540.000000"
    a12["root_permission"] := "false"
    a12["screen_brightness"] := "50"
    a12["show_frame_rate"] := "false"
    a12["system_disk_readonly"] := "true"
    a12["system_volume_close"] := "true"
    a12["vertical_sync"] := "false"
    a12["window_auto_rotate"] := "false"
    a12["window_save_rect"] := "true"
    a12["window_size_fixed"] := "false"
    a15 := {}
    a15["apk_asscciation"] := "true"
    a15["app_keptlive"] := "false"
    a15["dynamic_adjust_frame_rate"] := "false"
    a15["dynamic_low_frame_rate_limit"] := "15"
    a15["force_discrete_graphics"] := "true"
    a15["gpu_mode"] := "middle"
    a15["gpu_model.custom"] := "Adreno (TM) 640"
    a15["joystick_auto_connect"] := "false"
    a15["max_frame_rate"] := "30"
    a15["mini_disk"] := "false"
    a15["mouse_style"] := "true"
    a15["net_bridge_dns1"] := ""
    a15["net_bridge_dns2"] := ""
    a15["net_bridge_gateway"] := ""
    a15["net_bridge_ip_addr"] := ""
    a15["net_bridge_ip_mode"] := "dhcp"
    a15["net_bridge_open"] := "false"
    a15["net_bridge_subnet_mask"] := ""
    a15["performance_cpu.custom"] := "2"
    a15["performance_mem.custom"] := "2.000000"
    a15["performance_mode"] := "custom"
    a15["phone_brand"] := "Samsung"
    a15["phone_miit"] := "SM-G9980"
    a15["phone_model"] := "Galaxy S21 Ultra 5G"
    a15["phone_number"] := ""
    a15["quit_confirm"] := "false"
    a15["renderer_mode"] := "vk"
    a15["renderer_strategy"] := "auto"
    a15["resolution_dpi.custom"] := "220.000000"
    a15["resolution_height.custom"] := "960.000000"
    a15["resolution_mode"] := "custom"
    a15["resolution_width.custom"] := "540.000000"
    a15["root_permission"] := "false"
    a15["screen_brightness"] := "50"
    a15["show_frame_rate"] := "false"
    a15["system_disk_readonly"] := "true"
    a15["system_volume_close"] := "true"
    a15["vertical_sync"] := "false"
    a15["window_auto_rotate"] := "false"
    a15["window_save_rect"] := "true"
    a15["window_size_fixed"] := "false"
    return (androidMajor = "15") ? a15 : a12
}

; Returns the full paths of all apks in the apks folder, newest first.
GetApks() {
    apks := []
    Loop, Files, %apkFolder%\*.apk
    {
        ; Insert sorted by modification time, newest first.
        position := apks.Length() + 1
        for index, existing in apks {
            FileGetTime, existingTime, %existing%, M
            if (A_LoopFileTimeModified > existingTime) {
                position := index
                break
            }
        }
        apks.InsertAt(position, A_LoopFileFullPath)
    }
    return apks
}

; Drop down list entries (apk file names) for the given apk paths.
ApkDropDownItems(apks) {
    items := ""
    for _, apkPath in apks {
        SplitPath, apkPath, apkName
        items .= (items = "" ? "" : "|") . apkName
    }
    return items
}

; The mod menu apk needs the overlay permission.
IsModMenuApk(apkPath) {
    SplitPath, apkPath, apkName
    return InStr(apkName, "MODMENU") ? true : false
}

; Disables the whole GUI and tells the user where to put the apks while the apks
; folder is empty; enables it again once an apk shows up.
CheckApkFolder() {
    global apksMissing, apkFolder
    hasApks := GetApks().Length() > 0
    if (!hasApks && !apksMissing) {
        apksMissing := true
        SetGuiEnabled(false)
        MsgBox, 48, Update Manager, Put your apks in folder [%apkFolder%] to use the update manager
    } else if (hasApks && apksMissing) {
        apksMissing := false
        SetGuiEnabled(true)
    }
}

SetGuiEnabled(enabled) {
    action := enabled ? "Enable" : "Disable"
    for _, control in ["InstanceList", "RefreshButton", "AddButton", "ToggleButton", "UpdateApkButton"]
        GuiControl, Main:%action%, %control%
}

; Waits until Android has booted in the instance. Returns true when it is up.
WaitForAndroid(index, timeoutSeconds := 180) {
    deadline := A_TickCount + timeoutSeconds * 1000
    while (A_TickCount < deadline) {
        output := MuMuManagerCommand("info -v " . MuMuQuoteArg(index), true)
        if (RegExMatch(output, """is_android_started""\s*:\s*true"))
            return true
        Sleep, 2000
    }
    return false
}

; Runs an adb command in the instance through MuMuManager and returns its output.
MuMuAdb(index, cmd) {
    return MuMuManagerCommand("adb -v " . MuMuQuoteArg(index) . " -c " . MuMuQuoteArg(cmd), true)
}

; Allows the app to draw over other apps. Returns "" on success, otherwise an error message.
GrantOverlayPermission(index, package) {
    MuMuAdb(index, "connect")
    MuMuAdb(index, "shell cmd appops set " . package . " SYSTEM_ALERT_WINDOW allow")
    output := MuMuAdb(index, "shell cmd appops get " . package . " SYSTEM_ALERT_WINDOW")
    if (!InStr(output, "SYSTEM_ALERT_WINDOW: allow"))
        return "Could not enable the overlay permission for " . package . ":`n" . output
    return ""
}

; Kernel boot id of a running instance. It changes with every reboot, so it proves a
; restart really happened. Returns "" if it can't be read.
GetBootId(index) {
    MuMuAdb(index, "connect")
    output := MuMuAdb(index, "shell cat /proc/sys/kernel/random/boot_id")
    return RegExMatch(output, "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", bootId) ? bootId : ""
}

; Stops the instance and launches it again. Returns true once Android has booted.
HardRestartInstance(index) {
    MuMuManagerCommand("control -v " . MuMuQuoteArg(index) . " shutdown")
    deadline := A_TickCount + 60000
    while (A_TickCount < deadline) {
        output := MuMuManagerCommand("info -v " . MuMuQuoteArg(index), true)
        if (!RegExMatch(output, """is_process_started""\s*:\s*true"))
            break
        Sleep, 2000
    }
    MuMuManagerCommand("control -v " . MuMuQuoteArg(index) . " launch")
    return WaitForAndroid(index)
}

; Restarts the instances with the given indexes (comma separated) so the freshly
; installed apk is used, and waits until each one has really rebooted. An instance that
; ignores the restart is stopped and launched again.
; Returns "" on success, otherwise an error message.
RestartInstances(indexes) {
    pending := {}
    Loop, Parse, indexes, `,
        pending[A_LoopField] := GetBootId(A_LoopField)

    output := MuMuManagerCommand("control -v " . MuMuQuoteArg(indexes) . " restart", true)
    if (!(RegExMatch(output, """errcode""\s*:\s*(-?\d+)", match) && match1 = 0))
        return "Restarting failed:`n" . output

    deadline := A_TickCount + 90000
    while (A_TickCount < deadline && pending.Count() > 0) {
        Sleep, 3000
        done := []
        for index, oldId in pending {
            newId := GetBootId(index)
            ; Without a readable boot id before the restart we can't verify it.
            if (oldId = "" || (newId != "" && newId != oldId))
                done.Push(index)
        }
        for _, index in done
            pending.Delete(index)
    }

    failed := ""
    for index, _ in pending {
        SB_SetText("Instance " . index . " ignored the restart, stopping and launching it again...")
        if (!HardRestartInstance(index))
            failed .= (failed = "" ? "" : ", ") . index
    }
    return failed = "" ? "" : "Instance " . failed . " could not be restarted."
}

; Installs the apk in a running instance and restarts it. Android installs over an
; existing app as an update, so app data is kept. When grantOverlay is set, the
; app's overlay permission is enabled as well.
; Returns "" on success, otherwise an error message.
InstallApkOnRunning(index, apkPath, grantOverlay := false) {
    SB_SetText("Installing " . apkPath . "...")
    output := MuMuManagerCommand("control -v " . MuMuQuoteArg(index) . " app install --apk " . MuMuQuoteArg(apkPath), true)
    if (!RegExMatch(output, """package""\s*:\s*""([^""]+)""", match))
        return "Installing the apk failed:`n" . output

    error := ""
    if (grantOverlay) {
        SB_SetText("Enabling overlay permission...")
        error := GrantOverlayPermission(index, match1)
    }

    SB_SetText("Restarting instance " . index . "...")
    restartError := RestartInstances(index)
    return error != "" ? error : restartError
}

; Launches the instance, waits for Android to boot and installs the apk.
; Returns "" on success, otherwise an error message.
InstallApk(index, apkPath, grantOverlay := false) {
    SB_SetText("Launching instance " . index . "...")
    MuMuManagerCommand("control -v " . MuMuQuoteArg(index) . " launch")
    if (!WaitForAndroid(index))
        return "Instance " . index . " did not finish booting in time."
    return InstallApkOnRunning(index, apkPath, grantOverlay)
}

; Path of MuMuManager.exe, or "" if MuMu was not found.
MuMuManagerPath() {
    mumuFolder := getMuMuFolder()
    for _, subFolder in ["\shell", "\nx_main"] {
        managerPath := mumuFolder . subFolder . "\MuMuManager.exe"
        if (FileExist(managerPath))
            return managerPath
    }
    return ""
}

; Updates the apk on several running instances. The installs run simultaneously;
; the overlay permission (Mod Menu) is granted afterwards.
UpdateApks(targets, apkPath) {
    if (!FileExist(apkPath)) {
        MsgBox, 48, Update APK, The apk %apkPath% no longer exists.
        return
    }
    managerPath := MuMuManagerPath()
    if (managerPath = "") {
        MsgBox, 48, Update APK, MuMuManager.exe was not found.
        return
    }

    SetTimer, OnRefresh, Off
    results := {}
    jobs := []
    for _, target in targets {
        ; The list may be stale; make sure the instance is still booted.
        if (!WaitForAndroid(target.index, 1)) {
            results[target.index] := "not running"
            continue
        }
        outFile := A_Temp . "\ptcgpb_install_" . target.index . ".txt"
        FileDelete, %outFile%
        command := ComSpec . " /c """"" . managerPath . """ control -v " . target.index . " app install --apk """ . apkPath . """ > """ . outFile . """ 2>&1"""
        Run, %command%, , Hide, pid
        jobs.Push({target: target, pid: pid, outFile: outFile})
    }

    SB_SetText("Installing on " . jobs.Length() . " instance(s)...")
    deadline := A_TickCount + 600000
    Loop {
        pending := 0
        for _, job in jobs {
            Process, Exist, % job.pid
            if (ErrorLevel)
                pending++
        }
        if (pending = 0 || A_TickCount > deadline)
            break
        Sleep, 500
    }

    restartIndexes := ""
    for _, job in jobs {
        target := job.target
        FileRead, output, % job.outFile
        FileDelete, % job.outFile
        if (!RegExMatch(output, """package""\s*:\s*""([^""]+)""", match)) {
            results[target.index] := "install failed: " . Trim(output, " `r`n")
            continue
        }
        appVersions.Delete(target.index)
        results[target.index] := "updated"
        restartIndexes .= (restartIndexes = "" ? "" : ",") . target.index
        if (IsModMenuApk(apkPath)) {
            SB_SetText("Enabling overlay permission on """ . target.name . """...")
            overlayError := GrantOverlayPermission(target.index, match1)
            if (overlayError != "")
                results[target.index] := "updated, but " . overlayError
        }
    }

    ; Restart all updated instances so they run the new apk.
    if (restartIndexes != "") {
        SB_SetText("Restarting updated instances...")
        restartError := RestartInstances(restartIndexes)
        for _, target in targets {
            if (results[target.index] = "updated")
                results[target.index] := restartError = "" ? "updated and restarted" : "updated, but " . restartError
        }
    }

    SetTimer, OnRefresh, 5000
    RefreshInstanceList()
    SplitPath, apkPath, apkName
    summary := ""
    failed := false
    for _, target in targets {
        result := results.HasKey(target.index) ? results[target.index] : "no result"
        if (result != "updated and restarted")
            failed := true
        summary .= target.name . ": " . result . "`n"
    }
    MsgBox, % failed ? 48 : 64, Update APK, % apkName . "`n`n" . summary
}

; Creates an empty instance with the given Android version (12 or 15), applies
; the default settings to it and installs the given apk.
AddInstance(androidMajor, newName, apkPath) {
    if (!FileExist(apkPath)) {
        MsgBox, 48, Add Instance, The apk %apkPath% no longer exists.
        return
    }

    for _, instance in GetInstances() {
        if (instance.name = newName) {
            MsgBox, 48, Add Instance, An instance named "%newName%" already exists.
            return
        }
    }

    settings := GetDefaultSettings(androidMajor)
    settingsJson := ""
    for key, value in settings
        settingsJson .= (settingsJson = "" ? "" : ",`n") . "  """ . key . """: """ . value . """"
    settingsJson := "{`n" . settingsJson . "`n}`n"

    SB_SetText("Creating Android " . androidMajor . " instance...")
    ; Output is {"<new index>": {"errcode": 0, "errmsg": ""}}
    createOutput := MuMuManagerCommand("create -n 1 -ver " . MuMuQuoteArg(androidMajor), true)
    if (!RegExMatch(createOutput, "s)""(\d+)""\s*:\s*\{[^}]*""errcode""\s*:\s*0\b", match)) {
        RefreshInstanceList()
        MsgBox, 48, Add Instance, Creating the instance failed:`n%createOutput%
        return
    }
    newIndex := match1

    ; Settings are applied from a UTF-8 (no BOM) json file; the name is set by rename.
    settingsFile := A_Temp . "\ptcgpb_instance_settings.json"
    FileDelete, %settingsFile%
    FileOpen(settingsFile, "w", "UTF-8-RAW").Write(settingsJson)
    SB_SetText("Applying settings to instance " . newIndex . "...")
    applied := MuMuManagerCommand("setting -v " . MuMuQuoteArg(newIndex) . " --path " . MuMuQuoteArg(settingsFile))
    FileDelete, %settingsFile%
    MuMuManagerCommand("rename -v " . MuMuQuoteArg(newIndex) . " -n " . MuMuQuoteArg(newName))

    installError := InstallApk(newIndex, apkPath, IsModMenuApk(apkPath))
    RefreshInstanceList()

    SplitPath, apkPath, apkName
    message := "Created Android " . androidMajor . " instance """ . newName . """."
    if (!applied)
        message .= "`nApplying the settings reported an error."
    if (installError != "")
        MsgBox, 48, Add Instance, % message . "`n" . installError
    else
        MsgBox, % applied ? 64 : 48, Add Instance, % message . "`nInstalled " . apkName . (IsModMenuApk(apkPath) ? ", enabled the overlay permission" : "") . " and restarted the instance."
}
