Option Explicit

Dim sh, fso, here, root, htmlPath, htmlVer
Dim ps1, powerShellPath, args, command, exitCode

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
root = fso.GetAbsolutePathName(here & "\..\..")

ps1 = fso.BuildPath(here, "start_card_dashboard_server.ps1")
htmlPath = fso.BuildPath(here, "card_database.html")

powerShellPath = sh.ExpandEnvironmentStrings( _
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" _
)

If Not fso.FileExists(powerShellPath) Then
    MsgBox "PowerShell was not found:" & vbCrLf & powerShellPath, _
        vbCritical, "Card Database"
    WScript.Quit 1
End If

If Not fso.FileExists(ps1) Then
    MsgBox "Launcher script was not found:" & vbCrLf & ps1, _
        vbCritical, "Card Database"
    WScript.Quit 1
End If

htmlVer = "0"
If fso.FileExists(htmlPath) Then
    htmlVer = CStr(fso.GetFile(htmlPath).Size)
End If

args = "-NoProfile -File """ & ps1 & """" _
    & " -LaunchDashboard" _
    & " -Root """ & root & """" _
    & " -HtmlVersion """ & htmlVer & """"

command = """" & powerShellPath & """ " & args

' 1 = normal visible window
' True = wait and collect the exit code
exitCode = sh.Run(command, 1, True)

If exitCode <> 0 Then
    MsgBox "The dashboard launcher failed with exit code " _
        & CStr(exitCode) & ".", vbCritical, "Card Database"
End If
