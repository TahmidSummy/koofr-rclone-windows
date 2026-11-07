# Folder rename through a W: mount (same code path as Explorer on Z:).
# A: 8000 files, --timeout 30m  -> does Koofr itself fail a long move? how long does it take?
# B: 2000 files, --timeout 10s  -> does the VFS fallback delete files (the A1 data loss)?
$Lab = if ($env:KOOFR_LAB) { $env:KOOFR_LAB } else { 'E:\rclone-lab' }
$ErrorActionPreference = 'Continue'
$rc = (Get-Command rclone).Source
function MakeFiles([string]$dir, [int]$n) {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    1..40 | ForEach-Object { $d = "$dir\d$_"; New-Item -ItemType Directory -Force $d | Out-Null; $dd = $d; 1..($n / 40) | ForEach-Object { [IO.File]::WriteAllText("$dd\f$_.txt", "x$_") } }
}
function Count([string]$p) { @(& $rc lsf -R --files-only "koofr:_rclone-lab/$p" --disable-http2 2>$null).Count }
MakeFiles "$Lab\src-a" 8000
MakeFiles "$Lab\src-b" 2000
& $rc purge koofr:_rclone-lab --disable-http2 2>$null
& $rc copy "$Lab\src-a" koofr:_rclone-lab/bigA --disable-http2 --transfers 16 --tpslimit 40 --tpslimit-burst 40 --stats 0
& $rc copy "$Lab\src-b" koofr:_rclone-lab/bigB --disable-http2 --transfers 16 --tpslimit 40 --tpslimit-burst 40 --stats 0
"uploaded: bigA=$(Count bigA) bigB=$(Count bigB)  $(Get-Date -f HH:mm:ss)"

$flags = @('--vfs-cache-mode','full','--network-mode','--links','--no-console','--disable-http2','--transfers','16','--tpslimit','40','--tpslimit-burst','40','--dir-cache-time','1h','--vfs-write-back','10s','-vv','--dump','headers')
foreach ($case in @(@{Id='Y1'; T='30m'; From='bigA'; To='bigA-renamed'; N=8000}, @{Id='Y2'; T='10s'; From='bigB'; To='bigB-renamed'; N=2000})) {
    $log = "$Lab\logs\$($case.Id)-mount-rename.log"; Remove-Item $log -ErrorAction SilentlyContinue
    $cache = "$Lab\cache-$($case.Id)"
    $p = Start-Process $rc -ArgumentList (@('mount', 'koofr:_rclone-lab', 'W:', '--timeout', $case.T) + $flags + @('--cache-dir', $cache, '--log-file', $log)) -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 30 -and -not (Test-Path "W:\$($case.From)"); $i++) { Start-Sleep 1 }
    $null = Get-ChildItem "W:\$($case.From)" -ErrorAction SilentlyContinue
    $t0 = Get-Date
    $job = Start-Job { param($f, $t) $sw = [Diagnostics.Stopwatch]::StartNew(); try { Rename-Item "W:\$f" $t -ErrorAction Stop; $r = 'ok' } catch { $r = $_.Exception.Message }; "$r|$([math]::Round($sw.Elapsed.TotalSeconds,1))" } -ArgumentList $case.From, $case.To
    $null = Wait-Job $job -Timeout 2400
    $jr = if ($job.State -eq 'Completed') { Receive-Job $job } else { "still running after 40 min|-" }
    Remove-Job $job -Force
    Start-Sleep 45   # let a server-side move still running finish
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 3
    $lines = Get-Content $log
    # the Koofr files/move request(s) and their HTTP status
    $moveReq = for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -match 'PUT|POST' -and $lines[$k] -match '/move') { $lines[$k].Substring(0, 20) } }
    $status = $lines | Where-Object { $_ -match '^\S+ \S+ DEBUG : HTTP/1.1 \d{3}' -or $_ -match 'HTTP/1.1 (4|5)\d\d' } | Where-Object { $_ -match ' (4|5)\d\d ' } | Select-Object -First 5
    $fromN = Count $case.From; $toN = Count $case.To
    [pscustomobject]@{
        Test = "$($case.Id) mount, --timeout $($case.T), $($case.N) files"
        RenameStarted = $t0.ToString('HH:mm:ss'); RenameResult = ($jr -split '\|')[0]; RenameSeconds = ($jr -split '\|')[1]
        DirMoveFallback = [bool]($lines -match "Can't DirMove")
        FallbackAt = (($lines -match "Can't DirMove") | Select-Object -First 1) -replace '^(\S+ \S+).*', '$1'
        Deleted = @($lines -match ': Deleted$').Count
        Err404 = @($lines -match 'Got 404').Count
        HttpErrors = ($status -join ' || ')
        FilesFrom = $fromN; FilesTo = $toN; Lost = $case.N - $fromN - $toN
    } | Format-List | Out-String -Width 300
    Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
}
& $rc purge koofr:_rclone-lab --disable-http2
Remove-Item "$Lab\src-a", "$Lab\src-b" -Recurse -Force
