# Mount tests: a separate test mount of koofr:_rclone-lab on W: (your live Z: mount is never touched).
# Every test starts a fresh mount with an empty cache, so reads are "cold" (straight from Koofr).
. (Join-Path $PSScriptRoot 'lab.ps1')
$L = 'W:'
if (Test-Path "$L\") { throw "$L is already in use - pick another letter" }

# Your current Mount-Koofr.ps1 flags (minus cache dir / log file, which the lab sets per test).
$Current = @('--vfs-cache-mode','full','--network-mode','--links','--disable-http2','--dir-cache-time','1h',
             '--vfs-cache-max-age','999h','--vfs-cache-max-size','100G','--vfs-cache-poll-interval','15s',
             '--vfs-read-ahead','256M','--vfs-fast-fingerprint','--vfs-write-back','10s')
function Without([string[]]$Flags, [string]$Name) {   # drop a flag (and its value, if it has one)
    $out = @(); for ($i = 0; $i -lt $Flags.Count; $i++) {
        if ($Flags[$i] -eq $Name) { if ($i + 1 -lt $Flags.Count -and $Flags[$i + 1] -notlike '--*') { $i++ }; continue }
        $out += $Flags[$i] }
    ,$out
}

$big    = "$L\src\large\big1g.bin"
$bigLen = (Get-Item "$Lab\data\large\big1g.bin").Length

# ---- 1. Big-file reads (think: playing / copying a large video off Z:) ----
$readTests = @(
    @{ Id='M01'; Desc='1 GiB cold read, your current flags';                   Flags=$Current }
    @{ Id='M02'; Desc='1 GiB cold read, current + HTTP/2 ON';                  Flags=(Without $Current '--disable-http2') }
    @{ Id='M03'; Desc='1 GiB cold read, current + 4 parallel chunks x 16M';    Flags=($Current + @('--vfs-read-chunk-streams','4','--vfs-read-chunk-size','16M')) }
    @{ Id='M04'; Desc='1 GiB cold read, current + 8 parallel chunks x 16M';    Flags=($Current + @('--vfs-read-chunk-streams','8','--vfs-read-chunk-size','16M')) }
    @{ Id='M05'; Desc='1 GiB cold read, current + 16 parallel chunks x 8M';    Flags=($Current + @('--vfs-read-chunk-streams','16','--vfs-read-chunk-size','8M')) }
    @{ Id='M06'; Desc='1 GiB cold read, current + 8 parallel chunks x 32M';    Flags=($Current + @('--vfs-read-chunk-streams','8','--vfs-read-chunk-size','32M')) }
    @{ Id='M07'; Desc='1 GiB cold read, cache mode writes (no read cache)';    Flags=(@('--vfs-cache-mode','writes') + (Without (Without $Current '--vfs-cache-mode') '--vfs-read-ahead')) }
)
foreach ($t in $readTests) {
    $p = Start-TestMount -Letter $L -Flags $t.Flags -Id $t.Id
    try {
        $r = Read-FileTimed $big
        $note = if ($r.Bytes -ne $bigLen) { "short read: $($r.Bytes)" } else { '' }
        Add-Result -Id $t.Id -Group 'mount-read-large' -Desc $t.Desc -Flags ($t.Flags -join ' ') -Bytes $r.Bytes -Files 1 -Seconds $r.Seconds -ExitCode 0 -Note $note |
            Format-Table Id, Desc, Seconds, MiBps -AutoSize | Out-String -Width 200
        if ($t.Id -eq 'M01') {   # read it again: now it comes from the E: cache
            $r2 = Read-FileTimed $big
            Add-Result -Id 'M01w' -Group 'mount-read-large' -Desc '1 GiB warm read (2nd time, from E: cache), your current flags' -Flags ($t.Flags -join ' ') -Bytes $r2.Bytes -Files 1 -Seconds $r2.Seconds -ExitCode 0 |
                Format-Table Id, Desc, Seconds, MiBps -AutoSize | Out-String -Width 200
        }
    } finally { Stop-TestMount $p $L }
}
'READ TESTS DONE'
