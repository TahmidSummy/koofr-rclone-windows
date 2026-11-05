<#
    Check-KoofrHealth.ps1 - weekly look at the rclone and watchdog logs.
    Writes a summary to %USERPROFILE%\koofr-health.txt and only notifies you if something
    looks wrong (errors, rate-limit hits, stalls, restarts, low disk space, drive not mounted).
    Run weekly by the "Koofr Health Check" scheduled task. Run it by hand with -Always to get a
    notification either way.
#>
param(
    [string]$Letter   = 'Z:',
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'rclone-koofr-cache'),
    [string]$LogName  = 'rclone-Koofr.log',
    [int]$Days        = 7,
    [int]$MinFreeGB   = 15,
    [switch]$Always,
    [switch]$NoToast
)
. (Join-Path $PSScriptRoot 'KoofrCommon.ps1')
$script:KoofrNoToast = [bool]$NoToast

$since    = (Get-Date).AddDays(-$Days)
$logBase  = [IO.Path]::GetFileNameWithoutExtension($LogName)     # rclone-Koofr -> also matches rotated rclone-Koofr-<date>.log
$logs     = Get-ChildItem -LiteralPath $env:USERPROFILE -Filter "$logBase*.log" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $LogName -or $_.Name -match "^$([regex]::Escape($logBase))-\d{4}-\d\d-\d\dT" } |
            Where-Object { $_.LastWriteTime -ge $since }
$tsRegex  = '^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d) (\w+)\s*:\s*(.*)$'

function Read-SharedLines([string]$Path) {
    # rclone keeps its log open, so open it read-only while allowing rclone to keep writing.
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    $sr = New-Object IO.StreamReader($fs)
    try { while ($null -ne ($l = $sr.ReadLine())) { $l } } finally { $sr.Close() }
}

$errors = New-Object System.Collections.Generic.List[string]
$count  = @{ Error = 0; RateLimit = 0; Timeout = 0; UploadFail = 0 }
foreach ($f in $logs) {
    foreach ($line in (Read-SharedLines $f.FullName)) {
        if ($line -notmatch $tsRegex) { continue }
        $level = $Matches[2]; $msg = $Matches[3]
        if ($level -ne 'ERROR' -and $level -ne 'CRITICAL') { continue }
        if ([datetime]::ParseExact($Matches[1], 'yyyy/MM/dd HH:mm:ss', $null) -lt $since) { continue }
        $count.Error++
        if ($msg -match '\b429\b|Too Many Requests')                { $count.RateLimit++ }
        if ($msg -match 'timeout|deadline exceeded|i/o timeout')    { $count.Timeout++ }
        if ($msg -match 'upload|Failed to copy|failed to transfer') { $count.UploadFail++ }
        $short = $msg -replace '^[^:]{1,200}: ', ''      # group similar messages: drop the file name
        $errors.Add($short.Substring(0, [math]::Min(140, $short.Length)))
    }
}
$topErrors = $errors | Group-Object | Sort-Object Count -Descending | Select-Object -First 5

# What the watchdog did
$wd = @{ Frozen = 0; Dropped = 0; NoNet = 0; Failed = 0 }
if (Test-Path -LiteralPath $KoofrScriptLog) {
    foreach ($line in (Get-Content -LiteralPath $KoofrScriptLog)) {
        if ($line -notmatch '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)') { continue }
        if ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) -lt $since) { continue }
        if ($line -match 'still frozen - restarting')          { $wd.Frozen++ }
        if ($line -match 'TOAST: Koofr: .* had dropped')       { $wd.Dropped++ }
        if ($line -match 'no internet after')                  { $wd.NoNet++ }
        if ($line -match 'did not appear after|exited \(code') { $wd.Failed++ }
    }
}

$cacheRoot = [IO.Path]::GetPathRoot($CacheDir)
$free      = [math]::Round((Get-PSDrive $cacheRoot.Substring(0, 1) -ErrorAction SilentlyContinue).Free / 1GB, 1)
$up        = Test-Path "$Letter\"
$ver       = (& rclone.exe version 2>$null | Select-Object -First 1)

$problems = @()
if ($count.Error)      { $problems += "$($count.Error) rclone errors" }
if ($count.RateLimit)  { $problems += "$($count.RateLimit) rate-limit (429) hits" }
if ($wd.Frozen)        { $problems += "$($wd.Frozen) freeze restarts" }
if ($wd.Dropped)       { $problems += "$($wd.Dropped) drops" }
if ($wd.Failed)        { $problems += "$($wd.Failed) failed mounts" }
if ($free -lt $MinFreeGB) { $problems += "only $free GB free on $cacheRoot" }
if (-not $up)          { $problems += "$Letter is not mounted right now" }

$report = @"
Koofr health check - $(Get-Date -Format 'yyyy-MM-dd HH:mm') - last $Days days
====================================================================
Status:        $(if ($problems) { 'NEEDS A LOOK: ' + ($problems -join ', ') } else { 'all good' })
$Letter mounted:    $up
rclone:        $ver
Cache disk:    $cacheRoot  ($free GB free)

rclone log (ERROR/CRITICAL lines):
  total errors:           $($count.Error)
  rate limit (429):       $($count.RateLimit)
  timeouts / stalls:      $($count.Timeout)
  upload / copy failures: $($count.UploadFail)

Watchdog (koofr-mount-script.log):
  restarted a frozen drive: $($wd.Frozen)
  remounted a dropped drive: $($wd.Dropped)
  no internet at mount:     $($wd.NoNet)
  failed to mount:          $($wd.Failed)

Most common errors:
$(if ($topErrors) { ($topErrors | ForEach-Object { '  {0,4} x {1}' -f $_.Count, $_.Name }) -join "`r`n" } else { '  (none)' })

Logs checked: $(($logs | ForEach-Object Name) -join ', ')
"@
$out = Join-Path $env:USERPROFILE 'koofr-health.txt'
Set-Content -LiteralPath $out -Value $report -Encoding UTF8
Write-KLog ('health check: ' + $(if ($problems) { $problems -join ', ' } else { 'all good' }))
$report

if ($problems) {
    Show-Toast -Title 'Koofr: worth a look' -Body (($problems -join ', ') + '. Details in koofr-health.txt')
} elseif ($Always) {
    Show-Toast -Title 'Koofr: all good' -Body "No errors or restarts in the last $Days days."
}
