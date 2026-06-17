@echo off
setlocal

cd /d "%~dp0"
set "PORT=8081"
set "ROOT=%~dp0..\.."
for %%F in ("%~dp0card_database.html") do set "HTMLVER=%%~zF"
set "URL=http://localhost:%PORT%/Accounts/Cards/card_database.html?v=%HTMLVER%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$port=%PORT%; Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }"

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0start_card_dashboard_server.ps1','-Port','%PORT%','-Root','%ROOT%') -WorkingDirectory '%ROOT%' -WindowStyle Hidden"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$deadline=(Get-Date).AddSeconds(12); $ready=$false; while((Get-Date) -lt $deadline){ try { $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:%PORT%/__dashboard/ping' -TimeoutSec 1; if($r.StatusCode -eq 204){ $ready=$true; break } } catch {}; Start-Sleep -Milliseconds 200 }; if(-not $ready){ Write-Host 'Dashboard server did not become ready in time.' }"

start "" "%URL%"
