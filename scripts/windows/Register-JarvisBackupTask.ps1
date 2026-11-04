# Register-JarvisBackupTask.ps1 - create (or replace) the Task Scheduler task "JARVIS backup pull"
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Register-JarvisBackupTask.ps1
#
# Run once as the owner (normal, non-admin PowerShell). The task runs Pull-JarvisBackup.ps1 (same folder)
# daily at 9:00 AM local and 5 minutes after logon; a missed run starts as soon as the PC is on again.
# Runs only while the owner is logged on (Google Drive for Desktop needs the user session), hidden window,
# also on battery, max 1 h, never two at once.
# Remove: Unregister-ScheduledTask -TaskName 'JARVIS backup pull' -Confirm:$false
$ErrorActionPreference = 'Stop'

$name   = 'JARVIS backup pull'
$script = Join-Path $PSScriptRoot 'Pull-JarvisBackup.ps1'
$user   = "$env:USERDOMAIN\$env:USERNAME"

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$daily     = New-ScheduledTaskTrigger -Daily -At 9:00AM
$logon     = New-ScheduledTaskTrigger -AtLogOn -User $user
$logon.Delay = 'PT5M'
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $name -Force -Action $action -Trigger $daily, $logon -Settings $settings -Principal $principal `
    -Description "Copies the newest encrypted JARVIS backup into G:\My Drive\Jarvis Backups (keep 7). Source: homelab repo, scripts\windows\Pull-JarvisBackup.ps1" | Out-Null

Start-ScheduledTask -TaskName $name
Start-Sleep -Seconds 20
Get-ScheduledTask -TaskName $name | Get-ScheduledTaskInfo | Format-List LastRunTime, LastTaskResult, NextRunTime
Get-Content (Join-Path $env:LOCALAPPDATA 'JarvisBackupPull\pull.log') -Tail 2
