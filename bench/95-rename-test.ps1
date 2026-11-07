# Folder rename on a W: test mount: with vs without --links. Throwaway remote folder koofr:_rclone-lab.
$Lab = if ($env:KOOFR_LAB) { $env:KOOFR_LAB } else { 'E:\rclone-lab' }
$ErrorActionPreference = 'Continue'
$rc = (Get-Command rclone).Source
$base = @('--vfs-cache-mode','full','--network-mode','--no-console','--disable-http2','--transfers','16','--tpslimit','40','--tpslimit-burst','40','--timeout','1m','--dir-cache-time','1h','--vfs-write-back','10s','-vv')
$src = "$Lab\rename-src"
New-Item -ItemType Directory -Force "$src\sub" | Out-Null
1..6 | ForEach-Object { $b = New-Object byte[] (2MB); (New-Object Random).NextBytes($b); [IO.File]::WriteAllBytes("$src\sub\f$_.bin", $b) }
& $rc purge koofr:_rclone-lab --disable-http2 2>$null
$out = @()
foreach ($case in @(@{Id='R1'; Name='with --links'; Extra=@('--links')}, @{Id='R2'; Name='without --links'; Extra=@()})) {
    & $rc copy $src "koofr:_rclone-lab/$($case.Id)/before" --disable-http2
    $log = "$Lab\logs\$($case.Id)-rename.log"; Remove-Item $log -ErrorAction SilentlyContinue
    $cache = "$Lab\cache-rename-$($case.Id)"
    $p = Start-Process $rc -ArgumentList (@('mount', "koofr:_rclone-lab/$($case.Id)", 'W:') + $base + $case.Extra + @('--cache-dir', $cache, '--log-file', $log)) -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 30 -and -not (Test-Path 'W:\before'); $i++) { Start-Sleep 1 }
    $null = Get-ChildItem W:\before -Recurse
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { Rename-Item 'W:\before' 'after' -ErrorAction Stop; $ok = 'ok' } catch { $ok = $_.Exception.Message }
    $sw.Stop()
    Start-Sleep 3
    Stop-Process -Id $p.Id -Force; Start-Sleep 3
    $t = Get-Content $log
    $remote = (& $rc lsf -R --files-only "koofr:_rclone-lab/$($case.Id)" --disable-http2) -join ', '
    $out += [pscustomobject]@{
        Test = "$($case.Id) $($case.Name)"; Rename = $ok; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        DirMoveFallback = [bool]($t -match "Can't DirMove")
        ServerSideMoves = @($t -match 'Moved \(server-side\)').Count
        Downloads = @($t -match 'ChunkedReader|open source|>Open:').Count
        Remote = $remote
    }
    Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
}
& $rc purge koofr:_rclone-lab --disable-http2
Remove-Item $src -Recurse -Force
$out | Format-List | Out-String -Width 300
$out | Export-Csv "$Lab\results\rename-tests.csv" -NoTypeInformation
