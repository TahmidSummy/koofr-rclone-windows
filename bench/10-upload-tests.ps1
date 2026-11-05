# Upload tests: rclone copy from E: to a fresh folder on Koofr for every run.
. (Join-Path $PSScriptRoot 'lab.ps1')

$sets = @{
    small  = @{ Path = "$Lab\data\small";  Bytes = (Get-DirBytes "$Lab\data\small");  Files = 300 }
    medium = @{ Path = "$Lab\data\medium"; Bytes = (Get-DirBytes "$Lab\data\medium"); Files = 20 }
    large  = @{ Path = "$Lab\data\large";  Bytes = (Get-DirBytes "$Lab\data\large");  Files = 1 }
}

$tests = @(
    @{ Id='U01'; Set='small';  Flags=@('--transfers','4');                    Desc='300 x 64 KiB, HTTP/2 ON, 4 transfers (rclone defaults)' }
    @{ Id='U02'; Set='small';  Flags=@('--disable-http2','--transfers','4');  Desc='300 x 64 KiB, HTTP/2 OFF, 4 transfers (your current mount)' }
    @{ Id='U03'; Set='small';  Flags=@('--disable-http2','--transfers','8');  Desc='300 x 64 KiB, HTTP/2 OFF, 8 transfers' }
    @{ Id='U04'; Set='small';  Flags=@('--disable-http2','--transfers','16'); Desc='300 x 64 KiB, HTTP/2 OFF, 16 transfers' }
    @{ Id='U05'; Set='small';  Flags=@('--disable-http2','--transfers','32'); Desc='300 x 64 KiB, HTTP/2 OFF, 32 transfers' }
    @{ Id='U06'; Set='small';  Flags=@('--transfers','16');                   Desc='300 x 64 KiB, HTTP/2 ON, 16 transfers' }
    @{ Id='U07'; Set='medium'; Flags=@('--transfers','4');                    Desc='20 x 25 MiB, HTTP/2 ON, 4 transfers' }
    @{ Id='U08'; Set='medium'; Flags=@('--disable-http2','--transfers','4');  Desc='20 x 25 MiB, HTTP/2 OFF, 4 transfers' }
    @{ Id='U09'; Set='medium'; Flags=@('--disable-http2','--transfers','8');  Desc='20 x 25 MiB, HTTP/2 OFF, 8 transfers' }
    @{ Id='U10'; Set='medium'; Flags=@('--disable-http2','--transfers','16'); Desc='20 x 25 MiB, HTTP/2 OFF, 16 transfers' }
    @{ Id='U11'; Set='large';  Flags=@();                                     Desc='1 x 1 GiB, HTTP/2 ON (single stream)' }
    @{ Id='U12'; Set='large';  Flags=@('--disable-http2');                    Desc='1 x 1 GiB, HTTP/2 OFF (single stream)' }
)

foreach ($t in $tests) {
    $s = $sets[$t.Set]
    Invoke-RcloneTest -Id $t.Id -Group "upload-$($t.Set)" -Desc $t.Desc `
        -RcloneArgs @('copy', $s.Path, "$RemoteLab/up/$($t.Id)") -Flags $t.Flags -Bytes $s.Bytes -Files $s.Files |
        Format-Table Id, Desc, Seconds, MiBps, FilesPs, Exit -AutoSize | Out-String -Width 200
}

# Seed the download source once (not a test - just puts the files on Koofr for the download/mount tests).
& $Rclone copy "$Lab\data" "$RemoteLab/src" --exclude 'up50.bin' --disable-http2 --transfers 8 --log-file "$Lab\logs\seed.log" --log-level INFO
"seed exit: $LASTEXITCODE"
"UPLOAD TESTS DONE"
