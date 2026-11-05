# Cleanup: remove the test data from Koofr and E:, keep the report, results, logs and scripts.
. (Join-Path $PSScriptRoot 'lab.ps1')
if (Test-Path 'W:\') { throw 'Test mount W: still up - not cleaning' }
"Koofr lab folder before: " + ((& $Rclone size $RemoteLab --disable-http2 2>&1) -join ' | ')
& $Rclone purge $RemoteLab --disable-http2 --tpslimit 20 --log-file "$Lab\logs\cleanup.log" --log-level INFO
"purge exit: $LASTEXITCODE"
"lab folder still on Koofr: " + [bool]((& $Rclone lsf koofr: --dirs-only --disable-http2) -match '^_rclone-lab/$')
foreach ($d in 'data','cache','dl','bin175') {
    $p = Join-Path $Lab $d
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; "removed $p" }
}
"left in lab: " + ((Get-ChildItem $Lab | ForEach-Object Name) -join ', ')
"lab size now: {0:N1} MB" -f ((Get-DirBytes $Lab) / 1MB)
"E: free: {0:N1} GB" -f ((Get-PSDrive E).Free / 1GB)
"Koofr: " + ((& $Rclone about koofr: --disable-http2 2>&1) -join ' | ')
