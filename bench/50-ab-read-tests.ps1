# A/B repeat of the big-file mount read: current flags vs parallel chunks, interleaved so time-of-day
# swings in Koofr speed hit both equally. Each read has a 5-minute watchdog (M06 hung for 39 min).
# Usage: 50-ab-read-tests.ps1 [-RcloneExe path] [-Tag 174]
param([string]$RcloneExe = '', [string]$Tag = '174', [int]$Rounds = 2)
. (Join-Path $PSScriptRoot 'lab.ps1')
if ($RcloneExe) { $Rclone = $RcloneExe }
$ver = (& $Rclone version | Select-Object -First 1)
"using $ver"
$L = 'W:'
$Current = @('--vfs-cache-mode','full','--network-mode','--links','--disable-http2','--dir-cache-time','1h',
             '--vfs-cache-max-age','999h','--vfs-cache-max-size','100G','--vfs-cache-poll-interval','15s',
             '--vfs-read-ahead','256M','--vfs-fast-fingerprint','--vfs-write-back','10s')
$variants = [ordered]@{
    'cur'   = @{ Desc = 'current flags';               Flags = $Current }
    's16x8' = @{ Desc = 'current + 16 chunks x 8M';    Flags = ($Current + @('--vfs-read-chunk-streams','16','--vfs-read-chunk-size','8M')) }
    's8x32' = @{ Desc = 'current + 8 chunks x 32M (the M06 hang)'; Flags = ($Current + @('--vfs-read-chunk-streams','8','--vfs-read-chunk-size','32M')) }
}
for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($k in $variants.Keys) {
        $v  = $variants[$k]; $id = "AB$Tag-$k-r$r"
        $p  = Start-TestMount -Letter $L -Flags $v.Flags -Id $id
        $job = Start-Job -ScriptBlock {
            $buf = New-Object byte[] (1MB); $sw = [Diagnostics.Stopwatch]::StartNew()
            $fs = [IO.File]::Open('W:\src\large\big1g.bin', 'Open', 'Read', 'ReadWrite'); $t = [int64]0
            try { while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $t += $n } } finally { $fs.Close() }
            [pscustomobject]@{ Bytes = $t; Seconds = $sw.Elapsed.TotalSeconds }
        }
        if (Wait-Job $job -Timeout 300) {
            $res = Receive-Job $job
            $row = Add-Result -Id $id -Group "ab-read-$Tag" -Desc "1 GiB cold read, $($v.Desc), round $r ($ver)" -Flags ($v.Flags -join ' ') -Bytes $res.Bytes -Files 1 -Seconds $res.Seconds -ExitCode 0
        } else {
            $row = Add-Result -Id $id -Group "ab-read-$Tag" -Desc "1 GiB cold read, $($v.Desc), round $r ($ver)" -Flags ($v.Flags -join ' ') -Bytes 0 -Files 1 -Seconds 300 -ExitCode 1 -Note 'HUNG: no finish within 5 min, mount killed'
        }
        Stop-TestMount $p $L
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        "{0,-22} {1,8:N1}s {2,7:N1} MiB/s exit={3} {4}" -f $id, $row.Seconds, $row.MiBps, $row.Exit, $row.Note
        Start-Sleep -Seconds 10
    }
}
'AB DONE'
