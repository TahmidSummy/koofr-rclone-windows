# rclone + Koofr performance lab - shared helpers.
# Dot-source this file:  . (Join-Path $PSScriptRoot 'lab.ps1')
# Every test appends one row to E:\rclone-lab\results\results.csv and keeps its rclone log in E:\rclone-lab\logs.

$Lab        = if ($env:KOOFR_LAB) { $env:KOOFR_LAB } else { 'E:\rclone-lab' }   # set KOOFR_LAB to use another folder
$Rclone     = (Get-Command rclone -ErrorAction Stop).Source
$RemoteLab  = 'koofr:_rclone-lab'
$ResultsCsv = Join-Path $Lab 'results\results.csv'

function Get-DirBytes([string]$Path) {
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($s) { [int64]$s } else { [int64]0 }
}

function Add-Result {
    param([string]$Id, [string]$Group, [string]$Desc, [string]$Flags, [int64]$Bytes, [int]$Files, [double]$Seconds, [int]$ExitCode, [string]$Note = '')
    $row = [pscustomobject]@{
        Time     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Id       = $Id
        Group    = $Group
        Desc     = $Desc
        Flags    = $Flags
        MiB      = [math]::Round($Bytes / 1MB, 1)
        Files    = $Files
        Seconds  = [math]::Round($Seconds, 2)
        MiBps    = if ($Seconds -gt 0) { [math]::Round(($Bytes / 1MB) / $Seconds, 2) } else { 0 }
        FilesPs  = if ($Seconds -gt 0) { [math]::Round($Files / $Seconds, 2) } else { 0 }
        Exit     = $ExitCode
        Note     = $Note
    }
    $row | Export-Csv -LiteralPath $ResultsCsv -Append -NoTypeInformation -Encoding UTF8
    $row
}

# Runs one rclone command (array of args), timed, with its own log file.
function Invoke-RcloneTest {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][string[]]$RcloneArgs,
        [string[]]$Flags = @(),
        [int64]$Bytes,
        [int]$Files,
        [string]$Note = ''
    )
    $log = Join-Path $Lab "logs\$Id.log"
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    $all = $RcloneArgs + $Flags + @('--log-level', 'INFO', '--log-file', $log, '--stats', '5s', '--retries', '1', '--low-level-retries', '3')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Rclone @all 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $sw.Stop()
    Add-Result -Id $Id -Group $Group -Desc $Desc -Flags ($Flags -join ' ') -Bytes $Bytes -Files $Files -Seconds $sw.Elapsed.TotalSeconds -ExitCode $code -Note $Note
}

# Reads a file sequentially and throws the data away (measures read speed without writing anywhere).
function Read-FileTimed([string]$Path, [int]$BufferKB = 1024) {
    $buf = New-Object byte[] ($BufferKB * 1KB)
    $sw  = [Diagnostics.Stopwatch]::StartNew()
    $fs  = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    $total = [int64]0
    try { while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $total += $n } } finally { $fs.Close() }
    $sw.Stop()
    [pscustomobject]@{ Bytes = $total; Seconds = $sw.Elapsed.TotalSeconds }
}

# Starts a separate test mount (never touches the live Z: mount) and waits for it.
function Start-TestMount {
    param([string]$Letter = 'W:', [string[]]$Flags, [string]$Id)
    $cache = Join-Path $Lab "cache\$Id"
    if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force }
    $log = Join-Path $Lab "logs\$Id-mount.log"
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    $mArgs = @('mount', $RemoteLab, $Letter, '--cache-dir', $cache, '--log-level', 'INFO', '--log-file', $log, '--no-console') + $Flags
    $p = Start-Process -FilePath $Rclone -ArgumentList $mArgs -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path "$Letter\") { return $p } }
    throw "Test mount $Letter did not appear (see $log)"
}

function Stop-TestMount([System.Diagnostics.Process]$Proc, [string]$Letter = 'W:') {
    if ($Proc -and -not $Proc.HasExited) { Stop-Process -Id $Proc.Id -Force }
    for ($i = 0; $i -lt 40; $i++) { if (-not (Test-Path "$Letter\")) { break }; Start-Sleep -Milliseconds 250 }
    Start-Sleep -Seconds 1
}

# Makes a file of random (incompressible) bytes.
function New-RandomFile([string]$Path, [int64]$Size) {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] (4MB)
    $fs  = [IO.File]::Create($Path)
    try {
        $left = $Size
        while ($left -gt 0) {
            $n = [int][math]::Min($buf.Length, $left)
            $rng.GetBytes($buf)
            $fs.Write($buf, 0, $n)
            $left -= $n
        }
    } finally { $fs.Close() }
}
