@echo off
setlocal

cd /d "%~dp0"
set "PORT=8081"
set "LEGACY_PORT=8083"
set "ROOT=%~dp0..\.."
for %%F in ("%~dp0card_database.html") do set "HTMLVER=%%~zF"
set "URL=http://localhost:%PORT%/Accounts/Cards/card_database.html?v=%HTMLVER%"
set "CARDDB=%ROOT%\Helper\carddb.exe"
set "CARDDB_BUILD=%ROOT%\Helper\carddb_src\target\release\carddb.exe"

if exist "%CARDDB_BUILD%" (
  copy /Y "%CARDDB_BUILD%" "%CARDDB%" >nul 2>&1
  if errorlevel 1 set "CARDDB=%CARDDB_BUILD%"
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ports=@(%PORT%,%LEGACY_PORT%); foreach($port in $ports){ Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }"

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
  "Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0start_card_dashboard_server.ps1','-Port','%LEGACY_PORT%','-Root','%ROOT%') -WorkingDirectory '%ROOT%' -WindowStyle Hidden"

if exist "%CARDDB%" (
  powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
    "Start-Process -FilePath '%CARDDB%' -ArgumentList @('--root','%ROOT%','serve','--port','%PORT%','--legacy-port','%LEGACY_PORT%') -WorkingDirectory '%ROOT%' -WindowStyle Hidden"
) else (
  echo carddb.exe not found at %CARDDB% — falling back to legacy server only on port %LEGACY_PORT%
  set "PORT=%LEGACY_PORT%"
  set "URL=http://localhost:%PORT%/Accounts/Cards/card_database.html?v=%HTMLVER%"
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$deadline=(Get-Date).AddSeconds(20); $ready=$false; while((Get-Date) -lt $deadline){ try { $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:%PORT%/__dashboard/ping' -TimeoutSec 2; if($r.StatusCode -eq 204){ $ready=$true; break } } catch {}; Start-Sleep -Milliseconds 250 }; if(-not $ready){ Write-Host 'Dashboard server did not become ready in time.' }"

start "" "%URL%"
