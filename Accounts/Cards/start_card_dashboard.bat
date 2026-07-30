@echo off
setlocal

cd /d "%~dp0"
set "PORT=8081"
set "LEGACY_PORT=8083"
set "ROOT=%~dp0..\.."
for %%F in ("%~dp0card_database.html") do set "HTMLVER=%%~zF"
set "URL=http://localhost:%PORT%/Accounts/Cards/card_database.html?v=%HTMLVER%"
set "CARDDB=%ROOT%\Helper\carddb.exe"


powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$pidFile='%~dp0.dashboard_server.pid'; if(Test-Path -LiteralPath $pidFile){ $serverPid=[int](Get-Content -LiteralPath $pidFile -Raw); Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }; $serverScript='%~dp0start_card_dashboard_server.ps1'; Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($serverScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; $ports=@(%PORT%,%LEGACY_PORT%); foreach($port in $ports){ Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -ne 4 } | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }"

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
  "Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0start_card_dashboard_server.ps1','-Port','%LEGACY_PORT%','-Root','%ROOT%') -WorkingDirectory '%ROOT%' -WindowStyle Hidden"

if exist "%CARDDB%" (
  powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
    "Start-Process -FilePath '%CARDDB%' -ArgumentList @('--root','%ROOT%','serve','--port','%PORT%','--legacy-port','%LEGACY_PORT%') -WorkingDirectory '%ROOT%' -WindowStyle Hidden"
) else (
  echo carddb.exe not found at %CARDDB% — falling back to legacy server only on port %LEGACY_PORT%
  set "URL=http://localhost:%LEGACY_PORT%"
)

start "" "%URL%"
