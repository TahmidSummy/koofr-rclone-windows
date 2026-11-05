<#
.SYNOPSIS
    Sets up the Koofr drive: copies the scripts, creates the scheduled tasks and the refresh shortcut,
    then mounts the drive. Safe to run again (use -Force to replace existing tasks).

.DESCRIPTION
    Run from a NORMAL (not administrator) PowerShell window:
        powershell -ExecutionPolicy Bypass -File .\scripts\Install-KoofrMount.ps1 -CacheDir D:\rclone-koofr-cache

    Before running, you need: rclone 1.75.2+, WinFsp, and an rclone remote for Koofr (see README.md).

    Creates:
      - <InstallDir>\*.ps1                      the four scripts
      - Task "<TaskPrefix> Mount"               at logon (+30 s) and every 15 minutes (mount + watchdog)
      - Task "<TaskPrefix> Health Check"        Sundays 12:00 (runs late if the PC was off)
      - Desktop shortcut "Refresh Koofr (<letter>)"

.EXAMPLE
    .\Install-KoofrMount.ps1 -Letter Z: -Remote koofr: -CacheDir E:\rclone-koofr-cache -CacheMaxSize 100G
#>
param(
    [string]$Letter       = 'Z:',
    [string]$Remote       = 'koofr:',
    [string]$CacheDir     = (Join-Path $env:LOCALAPPDATA 'rclone-koofr-cache'),
    [string]$CacheMaxSize = '100G',
    [string]$MinFreeSpace = '10G',
    [string]$InstallDir   = (Join-Path $env:USERPROFILE 'KoofrMount'),
    [string]$TaskPrefix   = 'Koofr',
    [int]   $RcPort       = 5572,                 # use a different port for each extra drive
    [string]$LogName      = 'rclone-Koofr.log',   # use a different log name for each extra drive
    [switch]$NoShortcut,
    [switch]$NoStart,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
function Step([string]$m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "   ok  $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "   !!  $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "   XX  $m" -ForegroundColor Red; exit 1 }

if ($Letter -notmatch '^[A-Za-z]:$') { Fail "-Letter must look like Z: (got '$Letter')" }
$Letter = $Letter.ToUpper()

# ---------------------------------------------------------------- checks
Step 'Checking prerequisites'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Fail 'Run this from a NORMAL PowerShell window, not as administrator. A drive mounted by an admin process is invisible in your Explorer, and admin-created tasks can''t be edited later without admin.' }
Ok 'running as a normal user'

$rclone = Get-Command rclone.exe -ErrorAction SilentlyContinue
if (-not $rclone) { Fail 'rclone.exe not found on PATH. Install it:  winget install Rclone.Rclone   (then open a new PowerShell window)' }
$verLine = (& $rclone.Source version 2>$null | Select-Object -First 1)
if ($verLine -notmatch 'v(\d+)\.(\d+)\.(\d+)') { Fail "couldn't read the rclone version ('$verLine')" }
$ver = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
if ($ver -lt [version]'1.75.2') { Fail "rclone $ver is too old - need 1.75.2+ (parallel chunk reads hung on 1.74.2). Update:  winget upgrade Rclone.Rclone" }
Ok "rclone $ver ($($rclone.Source))"

$winfsp = @("${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-x64.dll", "$env:ProgramFiles\WinFsp\bin\winfsp-x64.dll") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $winfsp) { Fail 'WinFsp not found. Install it:  winget install WinFsp.WinFsp' }
Ok 'WinFsp installed'

$remoteName = ($Remote -split ':')[0] + ':'
if ((& $rclone.Source listremotes 2>$null) -notcontains $remoteName) { Fail "rclone has no remote called '$remoteName'. Create it first:  rclone config   (see README.md, step 3)" }
& $rclone.Source lsf $Remote --max-depth 1 --disable-http2 --timeout 30s --low-level-retries 2 --retries 1 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "couldn't list '$Remote' - check the remote with:  rclone lsd $Remote --disable-http2" }
Ok "remote '$Remote' works"

$letterInUse = Test-Path "$Letter\"
$ourMount = Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match "\smount\s+\S+\s+$([regex]::Escape($Letter))(\s|$)" }
if ($letterInUse -and -not $ourMount) { Fail "$Letter is already used by something else. Pick another letter with -Letter." }
if ($ourMount) { Warn "$Letter is already mounted by rclone (PID $($ourMount.ProcessId)) - it will be restarted with the new settings" } else { Ok "$Letter is free" }

$cacheRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($CacheDir))
$freeGB = [math]::Round((Get-PSDrive $cacheRoot.Substring(0, 1)).Free / 1GB, 1)
function To-GB([string]$s) { if ($s -match '^(\d+(?:\.\d+)?)([KMGT]?)$') { [double]$Matches[1] * @{ ''=1/1GB; 'K'=1/1MB; 'M'=1/1KB; 'G'=1; 'T'=1024 }[$Matches[2]] } else { 0 } }
Ok "cache: $CacheDir ($freeGB GB free on $cacheRoot)"
if ((To-GB $CacheMaxSize) -gt ($freeGB - (To-GB $MinFreeSpace))) {
    Warn "cache limit $CacheMaxSize is more than the free space allows - rclone will stop at $MinFreeSpace free anyway (--vfs-cache-min-free-space)"
}

# ---------------------------------------------------------------- tasks: check names before changing anything
$mountTask  = "$TaskPrefix Mount"
$healthTask = "$TaskPrefix Health Check"
foreach ($t in $mountTask, $healthTask) {
    if ((Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) -and -not $Force) {
        Fail "a scheduled task called '$t' already exists. Re-run with -Force to replace it, or pick another -TaskPrefix."
    }
}

# ---------------------------------------------------------------- copy scripts
Step "Copying scripts to $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($f in 'KoofrCommon.ps1', 'Mount-Koofr.ps1', 'Refresh-Koofr.ps1', 'Check-KoofrHealth.ps1') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $InstallDir -Force
    Ok $f
}
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

# ---------------------------------------------------------------- scheduled tasks
Step 'Creating scheduled tasks'
function Q([string]$s) { '"' + $s + '"' }          # quote an argument for the task command line
$hidden  = Join-Path $env:SystemRoot 'System32\conhost.exe'   # --headless = no console window flash
$psStart = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
$mountArgs  = "$psStart $(Q (Join-Path $InstallDir 'Mount-Koofr.ps1')) -Letter $Letter -Remote $(Q $Remote) -CacheDir $(Q $CacheDir) -CacheMaxSize $CacheMaxSize -MinFreeSpace $MinFreeSpace -RcPort $RcPort -LogName $(Q $LogName)"
$healthArgs = "$psStart $(Q (Join-Path $InstallDir 'Check-KoofrHealth.ps1')) -Letter $Letter -CacheDir $(Q $CacheDir) -LogName $(Q $LogName)"
$refreshArgs = "$psStart $(Q (Join-Path $InstallDir 'Refresh-Koofr.ps1')) -Letter $Letter -RcPort $RcPort"

$me   = "$env:USERDOMAIN\$env:USERNAME"
$prin = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited   # NOT highest privileges

$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $me
$atLogon.Delay = 'PT30S'
$first = (Get-Date).Date.AddMinutes([math]::Ceiling((Get-Date).TimeOfDay.TotalMinutes / 15) * 15)
$every15 = New-ScheduledTaskTrigger -Once -At $first -RepetitionInterval (New-TimeSpan -Minutes 15)
$mountSet = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
try {
    Register-ScheduledTask -TaskName $mountTask -Force -Principal $prin -Settings $mountSet -Trigger @($atLogon, $every15) `
        -Action (New-ScheduledTaskAction -Execute $hidden -Argument $mountArgs) `
        -Description "Mounts $Remote on $Letter at logon and checks it every 15 minutes (remounts / restarts rclone if needed). Silent when healthy." | Out-Null
    Ok "$mountTask  (at logon + every 15 min)"

    $weekly = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '12:00'
    $hSet   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $healthTask -Force -Principal $prin -Settings $hSet -Trigger $weekly `
        -Action (New-ScheduledTaskAction -Execute $hidden -Argument $healthArgs) `
        -Description 'Weekly check of the rclone/Koofr logs. Notifies only if something looks wrong.' | Out-Null
    Ok "$healthTask  (Sundays 12:00)"
} catch {
    Fail "couldn't create the tasks: $($_.Exception.Message). If a task with this name was created from an admin window, delete it in Task Scheduler (as admin) or use another -TaskPrefix."
}

# ---------------------------------------------------------------- shortcut
if (-not $NoShortcut) {
    Step 'Creating desktop shortcut'
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Refresh Koofr ($($Letter[0])).lnk"
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sc.TargetPath = $hidden; $sc.Arguments = $refreshArgs; $sc.WorkingDirectory = $InstallDir
    $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,238"
    $sc.Description = "Make $Letter show the latest changes from Koofr right now"
    $sc.Save()
    Ok $lnk
}

# ---------------------------------------------------------------- start
if ($NoStart) { Step 'Done (not started: -NoStart)'; exit 0 }
Step "Mounting $Letter"
if ($ourMount) {
    Warn 'stopping the old rclone mount (files waiting to upload resume automatically on the next start)'
    $ourMount | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    for ($i = 0; $i -lt 40 -and (Test-Path "$Letter\"); $i++) { Start-Sleep -Milliseconds 250 }
}
Start-ScheduledTask -TaskName $mountTask
for ($i = 0; $i -lt 90 -and -not (Test-Path "$Letter\"); $i++) { Start-Sleep -Seconds 1 }
if (-not (Test-Path "$Letter\")) { Fail "$Letter didn't appear within 90 s. Look at %USERPROFILE%\koofr-mount-script.log and %USERPROFILE%\$LogName" }
Ok "$Letter is mounted"
Write-Host "`nAll set. Open $Letter in Explorer. Logs: $env:USERPROFILE\koofr-mount-script.log and $env:USERPROFILE\$LogName" -ForegroundColor Green
