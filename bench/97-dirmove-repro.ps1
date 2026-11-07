# Reproduce the A1 data loss in miniature: a folder rename that outlasts --timeout.
# Koofr moves 2000 files in ~20-28 s, so --timeout 10s should cut the request off mid-move.
$Lab = if ($env:KOOFR_LAB) { $env:KOOFR_LAB } else { 'E:\rclone-lab' }
$ErrorActionPreference = 'Continue'
$N = 2000
$src = "$Lab\dirmove-src"
Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
1..40 | ForEach-Object { $d = "$src\d$_"; New-Item -ItemType Directory -Force $d | Out-Null; $dd = $d; 1..($N / 40) | ForEach-Object { [IO.File]::WriteAllText("$dd\f$_.txt", "x$_") } }
& rclone purge koofr:_rclone-lab --disable-http2 2>$null
& rclone copy $src koofr:_rclone-lab/big --disable-http2 --transfers 16 --tpslimit 40 --tpslimit-burst 40 --stats 0
function Count([string]$p) { @(& rclone lsf -R --files-only "koofr:_rclone-lab/$p" --disable-http2 2>$null).Count }
"start: big=$(Count big)"

foreach ($case in @(@{Id='X1'; T='10s'; From='big'; To='renamed'}, @{Id='X2'; T='10m'; From='renamed'; To='big'})) {
    # X1 uses the same per-file fallback a mount does (operations.DirMove); X2 is the fix.
    $log = "$Lab\logs\$($case.Id)-dirmove.log"; Remove-Item $log -ErrorAction SilentlyContinue
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & rclone moveto "koofr:_rclone-lab/$($case.From)" "koofr:_rclone-lab/$($case.To)" --disable-http2 --timeout $case.T --tpslimit 40 --tpslimit-burst 40 --low-level-retries 1 --retries 1 -v --log-file $log
    $s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Start-Sleep 40   # let any server-side move still running finish before counting
    $t = Get-Content $log
    [pscustomobject]@{
        Test = "$($case.Id) --timeout $($case.T): $($case.From) -> $($case.To)"; Seconds = $s
        Fallback = [bool]($t -match "Can't DirMove")
        DeletedLines = @($t -match ': Deleted').Count
        Err404 = @($t -match '404').Count
        Errors = @($t -match 'ERROR').Count
        FilesFrom = Count $case.From; FilesTo = Count $case.To; Expected = $N
    } | Format-List | Out-String -Width 250
    if ($case.Id -eq 'X1') {
        # put whatever survived back into one folder for X2 (copy-free server moves)
        & rclone move koofr:_rclone-lab/big koofr:_rclone-lab/renamed --disable-http2 --timeout 10m 2>$null
        "after X1 regroup: renamed=$(Count renamed) (lost $($N - (Count renamed)))"
    }
}
& rclone purge koofr:_rclone-lab --disable-http2
Remove-Item $src -Recurse -Force
