' Hidden launcher for Card Database (no console window).
Option Explicit

Dim sh, fso, here, root, htmlPath, htmlVer, ps1, args

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
root = fso.GetAbsolutePathName(here & "\..\..")
ps1 = here & "\start_card_dashboard_server.ps1"
htmlPath = here & "\card_database.html"
htmlVer = "0"
If fso.FileExists(htmlPath) Then htmlVer = CStr(fso.GetFile(htmlPath).Size)

' Ports are chosen dynamically by the PowerShell launcher (cached in .dashboard_ports.txt).
args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """" _
  & " -LaunchDashboard -Root """ & root & """" _
  & " -HtmlVersion """ & htmlVer & """"

' 0 = hidden window, False = do not wait
sh.Run "powershell.exe " & args, 0, False
