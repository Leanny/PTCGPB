#Include %A_ScriptDir%\Config.ahk
#Include %A_ScriptDir%\Profiler.ahk
#Include %A_ScriptDir%\Logging.ahk
#Include %A_ScriptDir%\Utils.ahk
#Include %A_ScriptDir%\AhkProcess.ahk

#SingleInstance, force
CoordMode, Mouse, Screen
SetTitleMatchMode, 3

if not A_IsAdmin
{
    ; Relaunch script with admin rights
    Run *RunAs "%A_ScriptFullPath%"
    ExitApp
}

global botConfig := new BotConfig()
botConfig.loadSettingsToConfig("ALL")

waitAfterBulkLaunch := botConfig.get("waitAfterBulkLaunch")
instanceLaunchDelay := botConfig.get("instanceLaunchDelay")
Instances := botConfig.get("Instances")
mumuFolder := botConfig.get("folderPath")

; Loop through each instance, check if it's started, and start it if it's not
launched := 0

nowEpoch := A_NowUTC
EnvSub, nowEpoch, 1970, seconds

Loop %Instances% {
    instanceNum := Format("{:u}", A_Index)

    IniRead, LastEndEpoch, %A_ScriptDir%\..\%instanceNum%.ini, Metrics, LastEndEpoch, 0
    secondsSinceLastEnd := nowEpoch - LastEndEpoch
    if(LastEndEpoch > 0 && secondsSinceLastEnd > (15 * 60))
    {
        ; msgbox, Killing Instance %instanceNum%! Last Run Completed %secondsSinceLastEnd% Seconds Ago
        msg := "Killing Instance " . instanceNum . "! Last Run Completed " . secondsSinceLastEnd . " Seconds Ago"
        LogInfo(msg, "Monitor.txt")

        scriptName := instanceNum . ".ahk"
        coverHwnd := CaptureMuMuCoverWindow(instanceNum)
        StoreMuMuCoverWindow(instanceNum, coverHwnd)

        killedAHK := killAHK(scriptName)
        killedInstance := killInstance(instanceNum)
        Sleep, 3000

        cntAHK := checkAHK(scriptName)
        pID := checkInstance(instanceNum)
        if not pID && not cntAHK {
            ; Change the last end date to now so that we don't keep trying to restart this beast
            IniWrite, %nowEpoch%, %A_ScriptDir%\..\%instanceNum%.ini, Metrics, LastEndEpoch

            launchInstance(instanceNum)

            sleepTime := instanceLaunchDelay * 1000
            Sleep, % sleepTime
            launched := launched + 1

            Sleep, %waitAfterBulkLaunch%

            ;Command := "Scripts\" . scriptName
            ;Run, %Command%
            scriptPath := A_ScriptDir "\.." "\" scriptName
            Run, "%A_AhkPath%" /restart "%scriptPath%"
        }
    }
}

ExitApp

~+F7::ExitApp
