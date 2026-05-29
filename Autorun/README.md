# Description
Autorun is a script that will start the PTCGPB bot in admin immediatly after Windows login is done without asking anything to the user and balance XML files.

# Usage
- Configure your AutoHotkey v1 path and PTCGPB_Leanny path in "autorun.bat". Configure the task to run (ex: %AutoHotkeyPath% "%PTCGPBPath%\PTCGPB.ahk" clicommand Inject13P)
- Go to the windows task scheduler (Windows + R => taskschd.msc)
- On the left, right click on Task Scheduler library and then right click on the middle => Create an empty task

# Configure the task
- In the General tab, set the name as PTCGPB_autorun and check "run with highest privilege". Select "Configure for" => Windows 10.
- In the Triggers Tab, click on New then Begin the task => At startup. Check Stop task if it runs longer than 1 day => Ok
- In the Action Tab, click New then Start a program => Browse => Select Autorun/autorun.bat => Ok
- In the Conditions Tab, uncheck "Stop if the computer switches battery to power" and "Start the task only if the computer is on AC power"
- In the Settings Tab, change "Stop the task if it runs longer than:" to "1 day" => Ok

As an example, export the task and compare it with Autorun\Task_scheduler_PTCGB_autorun.xml.
