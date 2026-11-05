# End-to-end test of the repo's Install-KoofrMount.ps1 / Uninstall-KoofrMount.ps1 on a throwaway W: drive.
# Uses its own task prefix, port, log, cache and install folder, so the live Z: setup is untouched.
param([string]$Repo)
$ErrorActionPreference = 'Continue'
$res = New-Object System.Collections.Generic.List[object]
function Pass([string]$n, [bool]$ok, [string]$d) { $res.Add([pscustomobject]@{ Test = $n; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detail = $d }) }
$P = @{ Letter = 'W:'; Remote = 'koofr:_rclone-lab'; CacheDir = 'E:\rclone-lab\cache-inst'; InstallDir = 'E:\rclone-lab\inst-test'; TaskPrefix = 'KoofrTEST'; LogName = 'rclone-insttest.log' }
$inst = Join-Path $Repo 'scripts\Install-KoofrMount.ps1'
$unin = Join-Path $Repo 'scripts\Uninstall-KoofrMount.ps1'
$common = "-Letter W: -Remote koofr:_rclone-lab -CacheDir E:\rclone-lab\cache-inst -InstallDir E:\rclone-lab\inst-test -TaskPrefix KoofrTEST -LogName rclone-insttest.log"
$zPid = (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object CommandLine -match '\smount\s+\S+\s+Z:(\s|$)').ProcessId

& rclone mkdir koofr:_rclone-lab --disable-http2

# I1 install
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$inst' $common -CacheMaxSize 5G -RcPort 5579" 2>&1 | Out-String
Pass 'I1 installer finishes' ($out -match 'All set') (($out -split "`n" | Where-Object { $_ -match 'XX|!!|All set' }) -join ' | ').Trim()
Pass 'I1 W: mounted' (Test-Path 'W:\') ''

# I2 tasks
$t = Get-ScheduledTask -TaskName 'KoofrTEST Mount' -ErrorAction SilentlyContinue
$h = Get-ScheduledTask -TaskName 'KoofrTEST Health Check' -ErrorAction SilentlyContinue
$trig = ($t.Triggers | ForEach-Object { ($_.CimClass.CimClassName -replace 'MSFT_Task', '') + $(if ($_.Repetition.Interval) { "/" + $_.Repetition.Interval } else { '' }) }) -join ','
Pass 'I2 mount task: logon + every 15 min, as user, not elevated' ($t -and $trig -match 'Logon' -and $trig -match 'PT15M' -and $t.Principal.RunLevel -eq 'Limited') "$trig, RunLevel=$($t.Principal.RunLevel)"
Pass 'I2 health task: weekly' ($h -and $h.Triggers[0].CimClass.CimClassName -match 'Weekly') ''
Pass 'I2 tasks run hidden (conhost --headless)' ($t.Actions[0].Execute -match 'conhost' -and $t.Actions[0].Arguments -match '--headless') $t.Actions[0].Arguments

# I3 rclone flags
$cl = (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object CommandLine -match '\smount\s+\S+\s+W:(\s|$)').CommandLine
$missing = @('--disable-http2','--transfers 16','--tpslimit 40','--timeout 1m','--vfs-read-chunk-streams 16','--vfs-cache-min-free-space 10G','--rc-addr 127.0.0.1:5579','--log-file-max-size 5M','rclone-insttest.log','cache-inst') | Where-Object { $cl -notlike "*$_*" }
Pass 'I3 rclone running with the tuned flags' (-not $missing) $(if ($missing) { 'missing: ' + ($missing -join ', ') } else { 'all present' })
Pass 'I3 rc password not on command line' ($cl -notmatch 'rc-pass') ''

# I4 watchdog run via the task = no change
$wPid = (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object CommandLine -match '\smount\s+\S+\s+W:(\s|$)').ProcessId
Start-ScheduledTask -TaskName 'KoofrTEST Mount'; Start-Sleep -Seconds 8
$wPid2 = (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object CommandLine -match '\smount\s+\S+\s+W:(\s|$)').ProcessId
Pass 'I4 scheduled watchdog run leaves a healthy drive alone' ($wPid -eq $wPid2 -and (Get-ScheduledTaskInfo 'KoofrTEST Mount').LastTaskResult -eq 0) "PID $wPid -> $wPid2, result $((Get-ScheduledTaskInfo 'KoofrTEST Mount').LastTaskResult)"

# I5 desktop shortcut works
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Refresh Koofr (W).lnk'
$slog = Join-Path $env:USERPROFILE 'koofr-mount-script.log'; $n0 = @(Get-Content $slog).Count
Start-Process -FilePath $lnk; Start-Sleep -Seconds 8
$new = @(Get-Content $slog | Select-Object -Skip $n0)
Pass 'I5 shortcut refreshes the drive' ((Test-Path $lnk) -and [bool]($new -match 'refresh: folder listings cleared for W:')) (($new -match 'refresh') -join ' | ')

# I6 re-run without -Force refuses
$out2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$inst' $common -RcPort 5579" 2>&1 | Out-String
Pass 'I6 re-install without -Force refuses' ($out2 -match 'already exists') (($out2 -split "`n" | Where-Object { $_ -match 'XX' }) -join '').Trim()

# I7 refuses a letter already in use by something else (C:)
$out3 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$inst' -Letter C: -Remote koofr:_rclone-lab -TaskPrefix KoofrTEST2 -NoStart" 2>&1 | Out-String
Pass 'I7 refuses a drive letter in use' ($out3 -match 'already used') (($out3 -split "`n" | Where-Object { $_ -match 'XX' }) -join '').Trim()

# I8 uninstall
$out4 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$unin' -Letter W: -TaskPrefix KoofrTEST -InstallDir E:\rclone-lab\inst-test -CacheDir E:\rclone-lab\cache-inst -LogName rclone-insttest.log -RemoveCache" 2>&1 | Out-String
Start-Sleep -Seconds 2
$left = @()
if (Get-ScheduledTask -TaskName 'KoofrTEST*' -ErrorAction SilentlyContinue) { $left += 'tasks' }
if (Test-Path 'W:\') { $left += 'W:' }
if (Test-Path $lnk) { $left += 'shortcut' }
if (Test-Path 'E:\rclone-lab\inst-test') { $left += 'install dir' }
if (Test-Path 'E:\rclone-lab\cache-inst') { $left += 'cache' }
Pass 'I8 uninstall removes everything' (-not $left) $(if ($left) { 'left: ' + ($left -join ', ') } else { 'clean' })
Pass 'I8 uninstall keeps shared state for the live Z: setup' ((Test-Path "$env:LOCALAPPDATA\KoofrMount\rc.pass") -and $out4 -match 'kept') (($out4 -split "`n" | Where-Object { $_ -match 'kept' }) -join '').Trim()

# live Z: untouched?
$zPid2 = (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object CommandLine -match '\smount\s+\S+\s+Z:(\s|$)').ProcessId
Pass 'Live Z: untouched' ($zPid -and $zPid -eq $zPid2 -and (Test-Path 'Z:\')) "PID $zPid -> $zPid2"
try { $null = & { . 'C:\Scripts\KoofrCommon.ps1'; Invoke-KoofrRc -Command 'core/version' -Port 5572 }; Pass 'Live Z: refresh still works' $true '' } catch { Pass 'Live Z: refresh still works' $false $_.Exception.Message }

# cleanup
& rclone purge koofr:_rclone-lab --disable-http2
Get-ChildItem $env:USERPROFILE -Filter 'rclone-insttest*.log' | Move-Item -Destination 'E:\rclone-lab\logs' -Force
$res | Format-Table -AutoSize -Wrap | Out-String -Width 220
$res | Export-Csv 'E:\rclone-lab\results\installer-tests.csv' -NoTypeInformation
