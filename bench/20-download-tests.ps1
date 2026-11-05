# Download tests: rclone copy from Koofr to E:, local copy wiped after every run.
. (Join-Path $PSScriptRoot 'lab.ps1')

$sets = @{
    small  = @{ Bytes = (Get-DirBytes "$Lab\data\small");  Files = 300 }
    medium = @{ Bytes = (Get-DirBytes "$Lab\data\medium"); Files = 20 }
    large  = @{ Bytes = (Get-DirBytes "$Lab\data\large");  Files = 1 }
}

$H2OFF = '--disable-http2'
$tests = @(
    @{ Id='D01'; Set='large';  Flags=@('--multi-thread-streams','4');                           Desc='1 GiB, HTTP/2 ON, 4 streams (rclone defaults)' }
    @{ Id='D02'; Set='large';  Flags=@($H2OFF,'--multi-thread-streams','0');                    Desc='1 GiB, HTTP/2 OFF, single stream' }
    @{ Id='D03'; Set='large';  Flags=@($H2OFF,'--multi-thread-streams','4');                    Desc='1 GiB, HTTP/2 OFF, 4 streams' }
    @{ Id='D04'; Set='large';  Flags=@($H2OFF,'--multi-thread-streams','8');                    Desc='1 GiB, HTTP/2 OFF, 8 streams' }
    @{ Id='D05'; Set='large';  Flags=@($H2OFF,'--multi-thread-streams','16');                   Desc='1 GiB, HTTP/2 OFF, 16 streams' }
    @{ Id='D06'; Set='large';  Flags=@($H2OFF,'--multi-thread-streams','8','--multi-thread-chunk-size','16M'); Desc='1 GiB, HTTP/2 OFF, 8 streams, 16M chunks' }
    @{ Id='D07'; Set='large';  Flags=@('--multi-thread-streams','16');                          Desc='1 GiB, HTTP/2 ON, 16 streams' }
    @{ Id='D08'; Set='medium'; Flags=@($H2OFF,'--transfers','4');                               Desc='20 x 25 MiB, HTTP/2 OFF, 4 transfers' }
    @{ Id='D09'; Set='medium'; Flags=@($H2OFF,'--transfers','8');                               Desc='20 x 25 MiB, HTTP/2 OFF, 8 transfers' }
    @{ Id='D10'; Set='medium'; Flags=@($H2OFF,'--transfers','16');                              Desc='20 x 25 MiB, HTTP/2 OFF, 16 transfers' }
    @{ Id='D11'; Set='medium'; Flags=@('--transfers','8');                                      Desc='20 x 25 MiB, HTTP/2 ON, 8 transfers' }
    @{ Id='D12'; Set='small';  Flags=@($H2OFF,'--transfers','4');                               Desc='300 x 64 KiB, HTTP/2 OFF, 4 transfers' }
    @{ Id='D13'; Set='small';  Flags=@($H2OFF,'--transfers','16');                              Desc='300 x 64 KiB, HTTP/2 OFF, 16 transfers' }
    @{ Id='D14'; Set='small';  Flags=@($H2OFF,'--transfers','32');                              Desc='300 x 64 KiB, HTTP/2 OFF, 32 transfers' }
    @{ Id='D15'; Set='small';  Flags=@('--transfers','16');                                     Desc='300 x 64 KiB, HTTP/2 ON, 16 transfers' }
)

foreach ($t in $tests) {
    $s = $sets[$t.Set]
    $dst = "$Lab\dl\$($t.Id)"
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    Invoke-RcloneTest -Id $t.Id -Group "download-$($t.Set)" -Desc $t.Desc `
        -RcloneArgs @('copy', "$RemoteLab/src/$($t.Set)", $dst) -Flags $t.Flags -Bytes $s.Bytes -Files $s.Files |
        Format-Table Id, Desc, Seconds, MiBps, FilesPs, Exit -AutoSize | Out-String -Width 200
    $got = Get-DirBytes $dst
    if ($got -ne $s.Bytes) { "  WARNING: $($t.Id) got $got bytes, expected $($s.Bytes)" }
    Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
}

# Listing: how long does it take to list a 300-file folder?
foreach ($t in @(
    @{ Id='L01'; Flags=@();       Desc='List 300-file folder, HTTP/2 ON' }
    @{ Id='L02'; Flags=@($H2OFF); Desc='List 300-file folder, HTTP/2 OFF' }
)) {
    Invoke-RcloneTest -Id $t.Id -Group 'listing' -Desc $t.Desc -RcloneArgs @('lsf', "$RemoteLab/src/small") -Flags $t.Flags -Bytes 0 -Files 300 |
        Format-Table Id, Desc, Seconds, FilesPs, Exit -AutoSize | Out-String -Width 200
}
"DOWNLOAD TESTS DONE"
