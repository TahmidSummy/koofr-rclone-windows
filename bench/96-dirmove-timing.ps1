# How long does Koofr take to move (rename) a folder with N files? Server-side DirMove timing.
$Lab = if ($env:KOOFR_LAB) { $env:KOOFR_LAB } else { 'E:\rclone-lab' }
param([int]$N = 2000)
$ErrorActionPreference = 'Continue'
$src = "$Lab\dirmove-src"
Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
1..40 | ForEach-Object { $d = "$src\d$_"; New-Item -ItemType Directory -Force $d | Out-Null; $dd = $d; 1..($N / 40) | ForEach-Object { [IO.File]::WriteAllText("$dd\f$_.txt", "x$_") } }
& rclone purge koofr:_rclone-lab --disable-http2 2>$null
$sw = [Diagnostics.Stopwatch]::StartNew()
& rclone copy $src koofr:_rclone-lab/big --disable-http2 --transfers 16 --tpslimit 40 --tpslimit-burst 40 --stats 0
"upload $N files: $([math]::Round($sw.Elapsed.TotalSeconds))s, remote count: $((& rclone lsf -R --files-only koofr:_rclone-lab/big --disable-http2).Count)"
foreach ($run in 1..2) {
    $from = if ($run -eq 1) { 'big' } else { 'big2' }; $to = if ($run -eq 1) { 'big2' } else { 'big' }
    $log = "$Lab\logs\DM-$N-$run.log"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & rclone moveto "koofr:_rclone-lab/$from" "koofr:_rclone-lab/$to" --disable-http2 --timeout 15m -vv --log-file $log
    $s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $t = Get-Content $log
    "DirMove $from -> $to : ${s}s, fallback: $([bool]($t -match "Can't DirMove|falling back")), server-side dir move: $([bool]($t -match 'DirMove'))"
}
& rclone purge koofr:_rclone-lab --disable-http2
Remove-Item $src -Recurse -Force
