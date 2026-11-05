<#
    Mount-Koofr.ps1 - mount Koofr as a Windows drive with rclone, and keep it healthy.
    ----------------------------------------------------------------------------------
    Run at logon AND every 15 minutes by the "Koofr Mount" scheduled task
    (Install-KoofrMount.ps1 sets that up). Each run:
      - drive mounted and responding  -> does nothing (silent, ~1 s)
      - drive frozen (not responding) -> checks again after 30 s, then restarts rclone + notifies
      - drive gone (rclone died)      -> remounts + notifies
      - no internet for 5 minutes     -> gives up this run + notifies (max once an hour)
      - rclone fails to start         -> notifies with rclone's own error message
    Everything it does is logged to %USERPROFILE%\koofr-mount-script.log.

    Run as your normal user, NOT as administrator: a drive mounted from an elevated
    process is invisible to your normal Explorer.

    The rclone flags below were benchmarked against Koofr - see docs/RESEARCH.md.
    Needs rclone 1.75.2 or newer (--vfs-read-chunk-streams hung once on 1.74.2).
#>
param(
    [string]$Letter       = 'Z:',                   # drive letter to mount on
    [string]$Remote       = 'koofr:',               # rclone remote (and optional path), e.g. 'koofr:' or 'koofr:Photos'
    [string]$CacheDir     = (Join-Path $env:LOCALAPPDATA 'rclone-koofr-cache'),   # put this on a fast local disk
    [string]$CacheMaxSize = '100G',                 # max size of the local cache
    [string]$MinFreeSpace = '10G',                  # always leave this much free on the cache disk
    [string]$LogName      = 'rclone-Koofr.log',     # rclone's own log, in %USERPROFILE%
    [int]   $RcPort       = 5572,                   # local remote-control port (used by Refresh-Koofr.ps1)
    [string]$RclonePath   = 'rclone.exe',           # full path if rclone isn't on PATH
    [switch]$NoToast                                # testing: log notifications instead of showing them
)
. (Join-Path $PSScriptRoot 'KoofrCommon.ps1')
$script:KoofrNoToast = [bool]$NoToast

# Only one copy per drive letter at a time (logon and watchdog runs can overlap).
$script:RunLock = New-Object System.Threading.Mutex($false, "Local\KoofrMountScript-$($Letter[0])")
try { if (-not $script:RunLock.WaitOne(0)) { exit 0 } } catch [System.Threading.AbandonedMutexException] { }

# ---- timing ----------------------------------------------------------------
$MaxAttempts     = 12        # checks for the drive after launching rclone
$RetryDelay      = 5         # seconds between checks
$InternetWaitMin = 5         # give up waiting for internet after this many minutes (next run retries)
$HealthTimeout   = 30        # seconds a folder listing may take before the drive counts as frozen

# ---- rclone flags (each one is explained, with test IDs, in config/mount-flags.md) ----
$LogPath = Join-Path $env:USERPROFILE $LogName
$MountFlags = @(
    '--vfs-cache-mode', 'full',              # cache reads and writes on local disk
    '--network-mode',                        # show as a network drive (Windows)
    '--links',                               # store symlinks as .rclonelink files
    '--no-console',
    '--disable-http2',                       # Koofr + Go HTTP/2 = big slowdowns (U11/U12, D01, M02)
    '--transfers', '16',                     # upload 16 files at once from the cache (W01 -> W03)
    '--tpslimit', '40',                      # stay under Koofr's 429 rate limit (D14/D15 failed, D17 ok)
    '--tpslimit-burst', '40',
    '--timeout', '1m',                       # drop a dead connection after 1 min, not 5 (U02)
    '--vfs-read-chunk-streams', '16',        # read big files in 16 parallel pieces, ~3x faster (AB tests)
    '--vfs-read-chunk-size', '8M',
    '--dir-cache-time', '1h',                # trust folder listings for an hour (Koofr has no change notify)
    '--vfs-cache-max-age', '999h',           # keep cached files a long time...
    '--vfs-cache-max-size', $CacheMaxSize,   # ...up to this size (oldest evicted first)...
    '--vfs-cache-min-free-space', $MinFreeSpace,  # ...and never fill the cache disk
    '--vfs-cache-poll-interval', '1m',       # default; shorter just fills the log
    '--vfs-read-ahead', '256M',              # prefetch ahead of reads (on disk, full mode only)
    '--vfs-fast-fingerprint',                # skip slow per-file metadata checks
    '--vfs-write-back', '10s',               # upload 10 s after a file is closed
    '--cache-dir', $CacheDir,
    '--log-level', 'INFO',
    '--log-file', $LogPath,
    '--log-file-max-size', '5M',             # rotate the log...
    '--log-file-max-backups', '3',           # ...keep 3 old ones
    '--rc', '--rc-addr', "127.0.0.1:$RcPort" # local-only remote control for the refresh shortcut
)


# --- Helpers ---------------------------------------------------------------

function Test-Internet {
    # TCP connect to 1.1.1.1:443 (more reliable than ping, which many networks block).
    # Only counts as "up" if the connection actually SUCCEEDED, not just finished.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('1.1.1.1', 443)
        return ($task.Wait(3000) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-Internet {
    $deadline = (Get-Date).AddMinutes($InternetWaitMin)
    while (-not (Test-Internet)) {
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Seconds $RetryDelay
    }
    return $true
}

# Is the drive there, and does it answer? Runs in a separate process so a frozen
# mount can't hang this script. Returns 'ok', 'missing' or 'frozen'.
$script:StuckJobs = @()
function Get-DriveState([string]$Drive) {
    $job = Start-Job -ArgumentList $Drive -ScriptBlock {
        param($d)
        if (-not (Test-Path "$d\")) { return 'missing' }
        $null = Get-ChildItem "$d\" -Force -ErrorAction Stop | Select-Object -First 1
        'ok'
    }
    if (Wait-Job $job -Timeout $HealthTimeout) {
        $r = Receive-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force
        if ($r -eq 'ok' -or $r -eq 'missing') { return $r }
        return 'frozen'        # listing threw an error
    }
    $script:StuckJobs += $job  # still hanging - cleaned up after rclone is killed
    return 'frozen'
}

function Get-MountProcess([string]$Drive) {
    Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "\smount\s+\S+\s+$([regex]::Escape($Drive))(\s|$)" }
}

function Stop-Mount([string]$Drive) {
    foreach ($p in @(Get-MountProcess $Drive)) {
        Write-KLog "killing rclone PID $($p.ProcessId) for $Drive"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 40 -and (Test-Path "$Drive\"); $i++) { Start-Sleep -Milliseconds 250 }
    $script:StuckJobs | Remove-Job -Force -ErrorAction SilentlyContinue
    $script:StuckJobs = @()
}

# The last ERROR/CRITICAL line rclone wrote since $Since (used when rclone fails to start).
function Get-RcloneFailReason([string]$Path, [datetime]$Since) {
    if (-not (Test-Path -LiteralPath $Path)) { return "no rclone log at $Path" }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
    try { $lines = $sr.ReadToEnd() -split "`r?`n" | Select-Object -Last 40 } finally { $sr.Close() }
    $line = $lines | Where-Object {
        $_ -match '^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d) (CRITICAL|ERROR)' -and
        [datetime]::ParseExact($Matches[1], 'yyyy/MM/dd HH:mm:ss', $null) -ge $Since.AddSeconds(-2)
    } | Select-Object -Last 1
    if ($line) { return ($line -replace '^\S+ \S+ \w+\s*:\s*', '') }
    return 'rclone exited without logging an error'
}

function Mount-KoofrDrive {
    $rcArgs = @('mount', $Remote, $Letter) + $MountFlags

    # Remote-control login comes from environment variables, so the password never shows in the process list.
    $cred = Get-RcCredential
    $env:RCLONE_RC_USER = $cred.User
    $env:RCLONE_RC_PASS = $cred.Pass

    Write-KLog "launching rclone for $Letter"
    $started = Get-Date
    # Detached, hidden: rclone keeps running after this script exits.
    $proc = Start-Process -FilePath $RclonePath -ArgumentList $rcArgs -WindowStyle Hidden -PassThru
    Remove-Item Env:\RCLONE_RC_USER, Env:\RCLONE_RC_PASS -ErrorAction SilentlyContinue

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        Start-Sleep -Seconds $RetryDelay
        if ($proc.HasExited) {
            # rclone quit straight away (bad config, drive letter taken, ...) - say why, don't wait a minute.
            $why = Get-RcloneFailReason $LogPath $started
            Write-KLog "rclone for $Letter exited (code $($proc.ExitCode)): $why" 'ERROR'
            Show-ToastThrottled -Key "fail-$($Letter[0])" -Minutes 60 -Title "Koofr: $Letter failed to start" -Body $why
            return $false
        }
        if (Test-Path "$Letter\") {
            Write-KLog "$Letter mounted after $($i * $RetryDelay)s (PID $($proc.Id))"
            return $true
        }
    }
    Write-KLog "$Letter did not appear after $($MaxAttempts * $RetryDelay)s" 'ERROR'
    Show-ToastThrottled -Key "fail-$($Letter[0])" -Minutes 60 -Title 'Failed to connect to Koofr' -Body "$Letter did not mount after $($MaxAttempts * $RetryDelay) seconds"
    return $false
}

# When did this Windows logon start? (explorer.exe start time) - tells
# "first mount after logon" apart from "the drive dropped and was brought back".
function Get-LogonTime {
    $e = Get-Process explorer -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
    if ($e) { $e.StartTime } else { (Get-Date).AddYears(-1) }
}


# --- Main ------------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Write-KLog 'Running elevated - the drive may be invisible to normal Explorer. Run as a standard user.' 'WARN' }

$okFlag = Join-Path $KoofrStateDir "mounted-$($Letter[0]).flag"

# 1. Already mounted? Make sure it actually answers.
$state = Get-DriveState $Letter
if ($state -eq 'ok') { exit 0 }    # healthy - nothing to do, stay silent

$reason = $null
if ($state -eq 'frozen') {
    Write-KLog "$Letter is not responding - checking again in 30s" 'WARN'
    Start-Sleep -Seconds 30
    if ((Get-DriveState $Letter) -eq 'ok') { Write-KLog "$Letter recovered on its own"; exit 0 }
    Write-KLog "$Letter still frozen - restarting rclone" 'WARN'
    Stop-Mount $Letter
    $reason = 'frozen'
} else {
    # Drive missing. If an rclone for it is still around, give it a moment, then clear it out.
    if (Get-MountProcess $Letter) {
        Start-Sleep -Seconds 20
        if ((Get-DriveState $Letter) -eq 'ok') { exit 0 }
        Write-KLog "rclone running but $Letter missing - clearing it" 'WARN'
        Stop-Mount $Letter
    }
    # Mounted earlier in THIS logon? Then it dropped (rclone died).
    if ((Test-Path -LiteralPath $okFlag) -and (Get-Item -LiteralPath $okFlag).LastWriteTime -gt (Get-LogonTime)) { $reason = 'dropped' }
}

# 2. Need the internet before mounting.
if (-not (Wait-Internet)) {
    Write-KLog "no internet after $InternetWaitMin min - not mounting this run" 'WARN'
    Show-ToastThrottled -Key 'nonet' -Minutes 60 -Title 'Koofr: no internet' -Body "$Letter is not mounted. Will keep retrying every 15 minutes."
    exit 1
}

# 3. Mount it.
if (Mount-KoofrDrive) {
    Set-Content -LiteralPath $okFlag -Value (Get-Date -Format o)
    if ($reason -eq 'frozen')  { Show-Toast -Title "Koofr: $Letter was frozen" -Body 'rclone was restarted and the drive is back.' }
    if ($reason -eq 'dropped') { Show-Toast -Title "Koofr: $Letter had dropped" -Body 'rclone had stopped. The drive has been remounted.' }
    exit 0
}
exit 1
