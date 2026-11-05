# Repeats: re-check the noisy / surprising results, and test --tpslimit against Koofr's 429 rate limit.
. (Join-Path $PSScriptRoot 'lab.ps1')
Start-Sleep -Seconds 90   # let Koofr's rate limiter cool down after D14/D15
$small = Get-DirBytes "$Lab\data\small"; $large = Get-DirBytes "$Lab\data\large"
$tests = @(
    @{ Id='D13b'; Set='small'; B=$small; F=300; Flags=@('--disable-http2','--transfers','16');                    Desc='300 x 64 KiB, HTTP/2 OFF, 16 transfers (repeat of D13)' }
    @{ Id='D15b'; Set='small'; B=$small; F=300; Flags=@('--transfers','16');                                      Desc='300 x 64 KiB, HTTP/2 ON, 16 transfers (repeat of D15, after cool-down)' }
    @{ Id='D14b'; Set='small'; B=$small; F=300; Flags=@('--disable-http2','--transfers','32','--tpslimit','20','--tpslimit-burst','20'); Desc='300 x 64 KiB, HTTP/2 OFF, 32 transfers, --tpslimit 20' }
    @{ Id='D16';  Set='small'; B=$small; F=300; Flags=@('--disable-http2','--transfers','16','--tpslimit','20','--tpslimit-burst','20'); Desc='300 x 64 KiB, HTTP/2 OFF, 16 transfers, --tpslimit 20' }
    @{ Id='D03b'; Set='large'; B=$large; F=1;   Flags=@('--disable-http2','--multi-thread-streams','4');          Desc='1 GiB, HTTP/2 OFF, 4 streams (repeat of D03)' }
    @{ Id='D01b'; Set='large'; B=$large; F=1;   Flags=@('--multi-thread-streams','4');                            Desc='1 GiB, HTTP/2 ON, 4 streams (repeat of D01)' }
    @{ Id='D05b'; Set='large'; B=$large; F=1;   Flags=@('--disable-http2','--multi-thread-streams','16');         Desc='1 GiB, HTTP/2 OFF, 16 streams (repeat of D05)' }
    @{ Id='D07b'; Set='large'; B=$large; F=1;   Flags=@('--multi-thread-streams','16');                           Desc='1 GiB, HTTP/2 ON, 16 streams (repeat of D07)' }
)
foreach ($t in $tests) {
    $dst = "$Lab\dl\$($t.Id)"
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    $r = Invoke-RcloneTest -Id $t.Id -Group "download-$($t.Set)" -Desc $t.Desc -RcloneArgs @('copy', "$RemoteLab/src/$($t.Set)", $dst) -Flags $t.Flags -Bytes $t.B -Files $t.F
    $got = Get-DirBytes $dst
    $n429 = @(Select-String -LiteralPath "$Lab\logs\$($t.Id).log" -Pattern ' 429' -ErrorAction SilentlyContinue).Count
    "{0,-5} {1,8:N2}s {2,7:N2} MiB/s {3,7:N1} files/s  exit={4}  got={5:N1} MiB  429s={6}" -f $t.Id, $r.Seconds, $r.MiBps, $r.FilesPs, $r.Exit, ($got/1MB), $n429
    Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 20
}
'REPEATS DONE'
