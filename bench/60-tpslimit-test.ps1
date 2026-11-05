# Rate-limit cap test: two 300-file downloads back to back (600 requests) with --tpslimit 40.
# Without a cap, ~550 requests in ~10 s triggered Koofr's 429 Too Many Requests (D14/D15).
. (Join-Path $PSScriptRoot 'lab.ps1')
$small = Get-DirBytes "$Lab\data\small"
foreach ($id in 'D17a','D17b') {
    $dst = "$Lab\dl\$id"
    $r = Invoke-RcloneTest -Id $id -Group 'download-small' -Desc '300 x 64 KiB, HTTP/2 OFF, 32 transfers, --tpslimit 40 (run back to back with the other D17)' `
        -RcloneArgs @('copy', "$RemoteLab/src/small", $dst) -Flags @('--disable-http2','--transfers','32','--tpslimit','40','--tpslimit-burst','40') -Bytes $small -Files 300
    $n429 = @(Select-String -LiteralPath "$Lab\logs\$id.log" -Pattern ' 429').Count
    $gotMiB = [math]::Round((Get-DirBytes $dst) / 1MB, 1)
    "{0} {1:N2}s {2:N1} files/s exit={3} got={4} MiB 429s={5}" -f $id, $r.Seconds, $r.FilesPs, $r.Exit, $gotMiB, $n429
    Remove-Item -LiteralPath $dst -Recurse -Force
}
