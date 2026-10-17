@REM To run autorun.bat in powershell, run the following command:
@REM Start-Process -FilePath "autorun.bat" -WorkingDirectory "C:\Users\l\Documents\PTCGPB_Leanny" -NoNewWindow

@REM Define variables
set AutoHotkeyPath="C:\Program Files\AutoHotkey\AutoHotkey.exe"
set PTCGPBPath="C:\Users\l\Documents\PTCGPB_Leanny"

@REM change current directory to PTCGPBPath
cd "%PTCGPBPath%"

@REM Start all mumu
%AutoHotkeyPath% "%PTCGPBPath%\Scripts\Include\LaunchAllMumu.ahk"

@REM Sleep 60s
timeout /t 60

@REM Execute a specific script without using the UI. This will run BalanceXML first. Supported commands :
@REM CreateBots13P, Inject13P, InjectWonderpick96P, InjectRewards
%AutoHotkeyPath% "%PTCGPBPath%\PTCGPB.ahk" clicommand Inject13P
