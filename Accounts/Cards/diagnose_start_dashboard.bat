@echo off
setlocal

cd /d "%~dp0"
set "PORT=8081"
set "LEGACY_PORT=8083"
set "ROOT=%~dp0..\.."
set "CARDDB=%ROOT%\Helper\carddb.exe"
set "LEGACY_SERVER=%~dp0start_card_dashboard_server.ps1"

for /f %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "STAMP=%%I"
set "LOG=%~dp0diagnose_start_dashboard_%STAMP%_summary.log"
set "PORT_CHECK_LOG=%~dp0diagnose_start_dashboard_%STAMP%_port_check.log"
set "PORT_STOP_LOG=%~dp0diagnose_start_dashboard_%STAMP%_port_stop.log"
set "LEGACY_LOG=%~dp0diagnose_start_dashboard_%STAMP%_legacy_server.log"
set "CARDDB_LOG=%~dp0diagnose_start_dashboard_%STAMP%_carddb.log"

echo Writing dashboard diagnosis to:
echo   %LOG%
echo   %PORT_CHECK_LOG%
echo   %PORT_STOP_LOG%
echo   %LEGACY_LOG%
echo   %CARDDB_LOG%
echo.

> "%LOG%" echo diagnose_start_dashboard.bat
>> "%LOG%" echo Started: %DATE% %TIME%
>> "%LOG%" echo Script directory: "%~dp0"
>> "%LOG%" echo Root: "%ROOT%"
>> "%LOG%" echo CARDDB: "%CARDDB%"
>> "%LOG%" echo Legacy server: "%LEGACY_SERVER%"
>> "%LOG%" echo Port: %PORT%
>> "%LOG%" echo Legacy port: %LEGACY_PORT%
>> "%LOG%" echo Summary log: "%LOG%"
>> "%LOG%" echo Port check log: "%PORT_CHECK_LOG%"
>> "%LOG%" echo Port stop log: "%PORT_STOP_LOG%"
>> "%LOG%" echo Legacy server log: "%LEGACY_LOG%"
>> "%LOG%" echo Carddb log: "%CARDDB_LOG%"
>> "%LOG%" echo.

>> "%LOG%" echo === Environment ===
>> "%LOG%" set OS
>> "%LOG%" set PROCESSOR_ARCHITECTURE
>> "%LOG%" echo.

>> "%LOG%" echo === Port Check ===
>> "%LOG%" echo Output: "%PORT_CHECK_LOG%"
> "%PORT_CHECK_LOG%" echo === Port Check ===
>> "%PORT_CHECK_LOG%" echo Started: %DATE% %TIME%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ports=@(%PORT%,%LEGACY_PORT%); foreach($port in $ports){ Write-Host ''; Write-Host ('Port ' + $port + ':'); $found=$false; try { $listeners=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop; foreach($listener in $listeners){ $found=$true; $ownerPid=$listener.OwningProcess; $proc=Get-Process -Id $ownerPid -ErrorAction SilentlyContinue; $name=if($proc){$proc.ProcessName}else{'unknown'}; Write-Host ('LISTEN pid=' + $ownerPid + ' process=' + $name + ' local=' + $listener.LocalAddress + ':' + $listener.LocalPort) } } catch { Write-Host ('Get-NetTCPConnection failed: ' + $_.Exception.Message) }; if(-not $found){ $netstat = netstat -ano | Select-String (':' + $port + '\s'); if($netstat){ $found=$true; $netstat | ForEach-Object { Write-Host $_.Line } } }; if(-not $found){ Write-Host 'No listener found.' } }" ^
  >> "%PORT_CHECK_LOG%" 2>&1
>> "%PORT_CHECK_LOG%" echo Finished: %DATE% %TIME%
>> "%LOG%" echo.

>> "%LOG%" echo === Stop Existing Port Listeners ===
>> "%LOG%" echo Output: "%PORT_STOP_LOG%"
> "%PORT_STOP_LOG%" echo === Stop Existing Port Listeners ===
>> "%PORT_STOP_LOG%" echo Started: %DATE% %TIME%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ports=@(%PORT%,%LEGACY_PORT%); foreach($port in $ports){ Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }" ^
  >> "%PORT_STOP_LOG%" 2>&1
>> "%PORT_STOP_LOG%" echo Finished: %DATE% %TIME%
>> "%LOG%" echo.

>> "%LOG%" echo === Legacy Server Check ===
if exist "%LEGACY_SERVER%" (
  >> "%LOG%" echo Found legacy server script.
) else (
  >> "%LOG%" echo Legacy server script not found at "%LEGACY_SERVER%"
  echo Legacy server script not found. Diagnosis log written to:
  echo   %LOG%
  exit /b 1
)
>> "%LOG%" echo.

>> "%LOG%" echo === Starting legacy PowerShell server ===
>> "%LOG%" echo Command: powershell -NoProfile -ExecutionPolicy Bypass -File "%LEGACY_SERVER%" -Port "%LEGACY_PORT%" -Root "%ROOT%"
>> "%LOG%" echo Output: "%LEGACY_LOG%"
>> "%LOG%" echo Started legacy server: %DATE% %TIME%
> "%LEGACY_LOG%" echo === Legacy PowerShell Server ===
>> "%LEGACY_LOG%" echo Command: powershell -NoProfile -ExecutionPolicy Bypass -File "%LEGACY_SERVER%" -Port "%LEGACY_PORT%" -Root "%ROOT%"
>> "%LEGACY_LOG%" echo Started: %DATE% %TIME%
start "card dashboard legacy server diagnosis" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%LEGACY_SERVER%" -Port "%LEGACY_PORT%" -Root "%ROOT%" >> "%LEGACY_LOG%" 2>&1
>> "%LOG%" echo Legacy server process was started in the background.
>> "%LOG%" echo.

>> "%LOG%" echo === CARDDB Check ===
if exist "%CARDDB%" (
  >> "%LOG%" echo Found carddb.exe.
) else (
  >> "%LOG%" echo carddb.exe not found at "%CARDDB%"
  echo carddb.exe not found. Diagnosis log written to:
  echo   %LOG%
  exit /b 1
)
>> "%LOG%" echo.

>> "%LOG%" echo === Running carddb serve ===
>> "%LOG%" echo Command: "%CARDDB%" --root "%ROOT%" serve --port "%PORT%" --legacy-port "%LEGACY_PORT%"
>> "%LOG%" echo Output: "%CARDDB_LOG%"
>> "%LOG%" echo Started command: %DATE% %TIME%
> "%CARDDB_LOG%" echo === carddb serve ===
>> "%CARDDB_LOG%" echo Command: "%CARDDB%" --root "%ROOT%" serve --port "%PORT%" --legacy-port "%LEGACY_PORT%"
>> "%CARDDB_LOG%" echo Started: %DATE% %TIME%
echo If it window stays open, that is expected. Close this window when done collecting the log. Two tabs should have been opened, report which tab is working and which is not.
echo.

start "" "http://localhost:8081/Accounts/Cards/card_database.html"
start "" "http://localhost:8083"

"%CARDDB%" --root "%ROOT%" serve --port "%PORT%" --legacy-port "%LEGACY_PORT%" >> "%CARDDB_LOG%" 2>&1

set "EXITCODE=%ERRORLEVEL%"
>> "%CARDDB_LOG%" echo.
>> "%CARDDB_LOG%" echo Command exited: %DATE% %TIME%
>> "%CARDDB_LOG%" echo Exit code: %EXITCODE%
>> "%LOG%" echo.
>> "%LOG%" echo carddb command exited: %DATE% %TIME%
>> "%LOG%" echo carddb exit code: %EXITCODE%
echo carddb serve exited with code %EXITCODE%.
echo Diagnosis logs written to:
echo   %LOG%
echo   %PORT_CHECK_LOG%
echo   %PORT_STOP_LOG%
echo   %LEGACY_LOG%
echo   %CARDDB_LOG%
exit /b %EXITCODE%
