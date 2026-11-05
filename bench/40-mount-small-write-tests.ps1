# Mount tests part 2: folder browsing, many small files, and writing (uploading) through the mount.
# Usage: 40-mount-small-write-tests.ps1 -Streams 8 -ChunkSize 16M   (best read setting from part 1)
param([int]$Streams = 8, [string]$ChunkSize = '16M')
. (Join-Path $PSScriptRoot 'lab.ps1')
$L = 'W:'
if (Test-Path "$L\") { throw "$L is already in use" }

$Current = @('--vfs-cache-mode','full','--network-mode','--links','--disable-http2','--dir-cache-time','1h',
             '--vfs-cache-max-age','999h','--vfs-cache-max-size','100G','--vfs-cache-poll-interval','15s',
             '--vfs-read-ahead','256M','--vfs-fast-fingerprint','--vfs-write-back','10s')
$Chunks = @('--vfs-read-chunk-streams', "$Streams", '--vfs-read-chunk-size', $ChunkSize)

# ---- 2. Folder browsing + reading 300 small files (think: opening a folder of photos/documents) ----
foreach ($t in @(
    @{ Id='S01'; Desc='List + read 300 x 64 KiB cold, your current flags';                       Flags=$Current }
    @{ Id='S02'; Desc="List + read 300 x 64 KiB cold, current + $Streams chunks x $ChunkSize";   Flags=($Current + $Chunks) }
    @{ Id='S03'; Desc='List + read 300 x 64 KiB cold, current minus --vfs-fast-fingerprint';     Flags=($Current | Where-Object { $_ -ne '--vfs-fast-fingerprint' }) }
)) {
    $p = Start-TestMount -Letter $L -Flags $t.Flags -Id $t.Id
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $files = Get-ChildItem "$L\src\small" -File
        $listSec = $sw.Elapsed.TotalSeconds
        $bytes = [int64]0
        foreach ($f in $files) { $bytes += (Read-FileTimed $f.FullName 64).Bytes }
        $sw.Stop()
        Add-Result -Id $t.Id -Group 'mount-small-files' -Desc $t.Desc -Flags ($t.Flags -join ' ') -Bytes $bytes -Files $files.Count -Seconds $sw.Elapsed.TotalSeconds -ExitCode 0 -Note ("listing took {0:N2}s" -f $listSec) |
            Format-Table Id, Desc, Seconds, FilesPs, Note -AutoSize | Out-String -Width 220
        # Warm: list again (dir cache) - should be instant
        $sw = [Diagnostics.Stopwatch]::StartNew(); $null = Get-ChildItem "$L\src\small" -File; $sw.Stop()
        Add-Result -Id "$($t.Id)w" -Group 'mount-small-files' -Desc 'Re-list same folder (warm dir cache)' -Flags ($t.Flags -join ' ') -Bytes 0 -Files 300 -Seconds $sw.Elapsed.TotalSeconds -ExitCode 0 |
            Format-Table Id, Desc, Seconds -AutoSize | Out-String -Width 200
    } finally { Stop-TestMount $p $L }
}

# ---- 3. Writing through the mount: copy 20 x 25 MiB onto W:, time until it is all on Koofr ----
function Wait-RemoteComplete([string]$RemotePath, [int]$Count, [int64]$Bytes, [int]$TimeoutSec = 900) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $j = & $Rclone lsjson $RemotePath --files-only --disable-http2 2>$null | ConvertFrom-Json
        if ($j -and @($j).Count -ge $Count -and ((@($j) | Measure-Object Size -Sum).Sum) -ge $Bytes) { return $true }
        Start-Sleep -Seconds 2
    }
    $false
}
$medBytes = Get-DirBytes "$Lab\data\medium"
foreach ($t in @(
    @{ Id='W01'; Desc='Write 20 x 25 MiB via mount, your current flags (4 uploads at once)'; Flags=$Current }
    @{ Id='W02'; Desc='Write 20 x 25 MiB via mount, current + --transfers 8';                Flags=($Current + @('--transfers','8')) }
    @{ Id='W03'; Desc='Write 20 x 25 MiB via mount, current + --transfers 16';               Flags=($Current + @('--transfers','16')) }
    @{ Id='W04'; Desc='Write 20 x 25 MiB via mount, --transfers 8 + --vfs-write-back 2s';    Flags=(($Current -replace '^10s$','2s') + @('--transfers','8')) }
)) {
    $p = Start-TestMount -Letter $L -Flags $t.Flags -Id $t.Id
    try {
        $dest = "$L\up-mount\$($t.Id)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        New-Item -ItemType Directory -Force $dest | Out-Null
        Copy-Item "$Lab\data\medium\*" $dest
        $localSec = $sw.Elapsed.TotalSeconds
        $ok = Wait-RemoteComplete "$RemoteLab/up-mount/$($t.Id)" 20 $medBytes
        $sw.Stop()
        Add-Result -Id $t.Id -Group 'mount-write' -Desc $t.Desc -Flags ($t.Flags -join ' ') -Bytes $medBytes -Files 20 -Seconds $sw.Elapsed.TotalSeconds -ExitCode ([int](-not $ok)) -Note ("copy to W: finished after {0:N1}s; rest is upload" -f $localSec) |
            Format-Table Id, Desc, Seconds, MiBps, Note -AutoSize | Out-String -Width 220
    } finally { Stop-TestMount $p $L }
}
'MOUNT PART 2 DONE'
