<#
.SYNOPSIS
    Removes what Install-KoofrMount.ps1 set up: unmounts the drive, deletes the scheduled tasks,
    the shortcut, the installed scripts and the private state folder.
    Your files on Koofr are never touched. The local cache and logs are kept unless you ask.

.EXAMPLE
    .\Uninstall-KoofrMount.ps1                       # keep cache + logs
    .\Uninstall-KoofrMount.ps1 -RemoveCache -RemoveLogs -CacheDir E:\rclone-koofr-cache
#>
param(
    [string]$Letter     = 'Z:',
    [string]$TaskPrefix = 'Koofr',
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'KoofrMount'),
    [string]$CacheDir   = (Join-Path $env:LOCALAPPDATA 'rclone-koofr-cache'),
    [string]$LogName    = 'rclone-Koofr.log',
    [switch]$RemoveCache,
    [switch]$RemoveLogs,
    [switch]$Force                                   # unmount even if uploads look pending
)
$Letter = $Letter.ToUpper()

# Don't cut off uploads that are still waiting in the cache.
$log = Join-Path $env:USERPROFILE $LogName
if ((Test-Path $log) -and -not $Force) {
    $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
    try { $last = ($sr.ReadToEnd() -split "`r?`n" | Select-String 'vfs cache: cleaned' | Select-Object -Last 1) } finally { $sr.Close() }
    if ($last -and $last.Line -notmatch 'to upload 0, uploading 0') {
        Write-Host "Files are still uploading:`n  $($last.Line -replace '^.*vfs cache','vfs cache')`nWait for it to finish, or re-run with -Force." -ForegroundColor Yellow
        exit 1
    }
}

foreach ($t in "$TaskPrefix Mount", "$TaskPrefix Health Check") {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop; "removed task: $t" }
        catch { "couldn't remove task '$t' ($($_.Exception.Message)) - delete it in Task Scheduler" }
    }
}

Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" |
    Where-Object { $_.CommandLine -match "\smount\s+\S+\s+$([regex]::Escape($Letter))(\s|$)" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "stopped rclone mount on $Letter (PID $($_.ProcessId))" }

$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Refresh Koofr ($($Letter[0])).lnk"
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; "removed shortcut: $lnk" }

if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force; "removed: $InstallDir" }

# Private state (%LOCALAPPDATA%\KoofrMount): drop this drive's flags; remove the whole folder only if
# no other Koofr drive is still set up (another drive's refresh shortcut needs the shared rc password).
$state = Join-Path $env:LOCALAPPDATA 'KoofrMount'
if (Test-Path -LiteralPath $state) {
    Get-ChildItem -LiteralPath $state -File | Where-Object { $_.Name -match "^(mounted|toast-fail)-$($Letter[0])\.flag$" } | Remove-Item -Force
    $others = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { ($_.Actions | ForEach-Object { $_.Arguments }) -match 'Mount-Koofr\.ps1' }
    if (-not $others) { Remove-Item -LiteralPath $state -Recurse -Force; "removed: $state" }
    else { "kept $state (still used by: $(($others.TaskName) -join ', '))" }
}
if ($RemoveCache -and (Test-Path -LiteralPath $CacheDir)) { Remove-Item -LiteralPath $CacheDir -Recurse -Force; "removed cache: $CacheDir" }
if ($RemoveLogs) {
    Get-ChildItem -LiteralPath $env:USERPROFILE -File | Where-Object { $_.Name -match '^(rclone-Koofr.*\.log|koofr-mount-script\.log(\.old)?|koofr-health\.txt)$' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; "removed log: $($_.Name)" }
}
'Done. Your Koofr files are untouched; rclone and WinFsp are still installed.'
