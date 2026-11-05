# Smoke test: mount W: with exactly the recommended flags on rclone 1.75.2, read the 1 GiB file, check the log.
. (Join-Path $PSScriptRoot 'lab.ps1')
# (originally run with a portable 1.75.2 copy; now uses rclone on PATH)
$tok = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw (Join-Path $PSScriptRoot '..\scripts\Mount-Koofr.ps1')), [ref]$null) | Out-Null
$errs = $null; [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\scripts\Mount-Koofr.ps1'), [ref]$null, [ref]$errs) | Out-Null
"script parse errors: $(@($errs).Count)"
$Rec = @('--vfs-cache-mode','full','--network-mode','--links','--disable-http2','--transfers','16','--tpslimit','40','--tpslimit-burst','40',
         '--timeout','1m','--vfs-read-chunk-streams','16','--vfs-read-chunk-size','8M','--dir-cache-time','1h','--vfs-cache-max-age','999h',
         '--vfs-cache-max-size','100G','--vfs-cache-min-free-space','10G','--vfs-cache-poll-interval','1m','--vfs-read-ahead','256M',
         '--vfs-fast-fingerprint','--vfs-write-back','10s','--log-file-max-size','5M','--log-file-max-backups','3')
$p = Start-TestMount -Letter 'W:' -Flags $Rec -Id 'SMOKE'
try {
    $r = Read-FileTimed 'W:\src\large\big1g.bin'
    Add-Result -Id 'SMOKE' -Group 'smoke' -Desc '1 GiB cold read, full recommended flags, rclone 1.75.2' -Flags ($Rec -join ' ') -Bytes $r.Bytes -Files 1 -Seconds $r.Seconds -ExitCode 0 |
        Format-Table Id, Seconds, MiBps -AutoSize | Out-String
} finally { Stop-TestMount $p 'W:' }
"log errors/unknown flags:"; Select-String -Path "$Lab\logs\SMOKE-mount.log" -Pattern 'ERROR|unknown|invalid|CRITICAL' | ForEach-Object { $_.Line }
'SMOKE DONE'
