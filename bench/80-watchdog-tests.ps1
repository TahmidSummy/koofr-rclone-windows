# Tests for the new Mount-Koofr.ps1 watchdog, Refresh-Koofr.ps1 and Check-KoofrHealth.ps1.
# Uses a throwaway W: mount of koofr:_rclone-lab (Z: is never touched) and -NoToast (toasts are logged, not shown).
$ErrorActionPreference = 'Continue'
$S       = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts')).Path   # this repo's scripts
$Lab     = if ($env:KOOFR_LAB) { $env:KOOFR_LAB } else { 'E:\rclone-lab' }
$SLog    = Join-Path $env:USERPROFILE 'koofr-mount-script.log'
$State   = Join-Path $env:LOCALAPPDATA 'KoofrMount'
$W       = @('-Letter','W:','-Remote','koofr:_rclone-lab','-CacheDir',"$Lab\cache-wd",'-LogName','rclone-wdtest.log','-RcPort','5573','-NoToast')
$results = New-Object System.Collections.Generic.List[object]
function Pass([string]$Name, [bool]$Ok, [string]$Detail) { $results.Add([pscustomobject]@{ Test = $Name; Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail }) }
function Run-Mount([string[]]$MArgs) {
    $before = if (Test-Path $SLog) { @(Get-Content $SLog).Count } else { 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$S\Mount-Koofr.ps1" @MArgs | Out-Null
    $sw.Stop()
    $new = if (Test-Path $SLog) { @(Get-Content $SLog | Select-Object -Skip $before) } else { @() }
    [pscustomobject]@{ Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Lines = $new }
}
function WProc { Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match '\smount\s+\S+\s+W:(\s|$)' } }

# keep the real script log out of the test
if (Test-Path $SLog) { Move-Item $SLog "$SLog.pretest" -Force }
& rclone mkdir koofr:_rclone-lab --disable-http2
'hello' | Set-Content "$Lab\hello.txt"; & rclone copy "$Lab\hello.txt" koofr:_rclone-lab --disable-http2; Remove-Item "$Lab\hello.txt"

# T1 - all scripts parse
foreach ($f in 'KoofrCommon.ps1','Mount-Koofr.ps1','Refresh-Koofr.ps1','Check-KoofrHealth.ps1') {
    $e = $null; [System.Management.Automation.Language.Parser]::ParseFile("$S\$f", [ref]$null, [ref]$e) | Out-Null
    Pass "T1 parse $f" (@($e).Count -eq 0) "$(@($e).Count) errors"
}

# T2 - internet check: new logic vs old logic on a refused port, an unreachable address, and 1.1.1.1
function New-Check([string]$H, [int]$P) { $c = New-Object Net.Sockets.TcpClient; try { $t = $c.ConnectAsync($H, $P); ($t.Wait(3000) -and $c.Connected) } catch { $false } finally { $c.Close() } }
function Old-Check([string]$H, [int]$P) { try { $c = New-Object Net.Sockets.TcpClient; $a = $c.BeginConnect($H, $P, $null, $null); $ok = $a.AsyncWaitHandle.WaitOne(3000, $false); $c.Close(); $ok } catch { $false } }
Pass 'T2 internet up (1.1.1.1:443)'      (New-Check '1.1.1.1' 443)        "new=$(New-Check '1.1.1.1' 443)"
Pass 'T2 refused port counts as down'     (-not (New-Check '127.0.0.1' 1)) "new=$(New-Check '127.0.0.1' 1)  old=$(Old-Check '127.0.0.1' 1)  (old said up = the bug)"
Pass 'T2 unreachable counts as down'      (-not (New-Check '10.255.255.1' 443)) "new=$(New-Check '10.255.255.1' 443)"

# T3 - fresh mount
$r = Run-Mount $W
$up = Test-Path 'W:\'
Pass 'T3 fresh mount comes up' $up "W: up=$up in $($r.Seconds)s; log: $(($r.Lines | Select-Object -Last 1) -replace '^.{29}','')"
$cl = (WProc).CommandLine
Pass 'T3 rc password not on command line' ($cl -notmatch 'rc-pass|rc-user') 'checked rclone command line'
try { $v = (& { . "$S\KoofrCommon.ps1"; Invoke-KoofrRc -Command 'core/version' -Port 5573 }).version; Pass 'T3 remote control answers (with password)' ([bool]$v) "rclone $v" } catch { Pass 'T3 remote control answers (with password)' $false $_.Exception.Message }
try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:5573/core/version' -TimeoutSec 5 | Out-Null; Pass 'T3 remote control refuses no password' $false 'answered without auth!' } catch { Pass 'T3 remote control refuses no password' ($_.Exception.Message -match '401|Unauthorized') $_.Exception.Message }

# T4 - healthy mount: watchdog run does nothing
$pidBefore = (WProc).ProcessId
$r = Run-Mount $W
Pass 'T4 healthy: no action, same rclone' (((WProc).ProcessId -eq $pidBefore) -and $r.Lines.Count -eq 0) "took $($r.Seconds)s, $($r.Lines.Count) log lines"

# T5 - refresh shortcut script
$before = if (Test-Path $SLog) { @(Get-Content $SLog).Count } else { 0 }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$S\Refresh-Koofr.ps1" -RcPort 5573 -NoToast | Out-Null
$new = @(Get-Content $SLog | Select-Object -Skip $before)
Pass 'T5 refresh works' ([bool]($new -match 'refresh: folder listings cleared')) (($new -match 'TOAST') -replace '^.{29}','' -join ' | ')

# T6 - frozen mount: suspend rclone, watchdog should restart it
Add-Type -Namespace Lab -Name Nt -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(System.IntPtr h);'
$p = WProc; [void][Lab.Nt]::NtSuspendProcess([Diagnostics.Process]::GetProcessById($p.ProcessId).Handle)
$r = Run-Mount $W
$newPid = (WProc).ProcessId
Pass 'T6 frozen: detected, restarted, back up' ((Test-Path 'W:\') -and $newPid -and $newPid -ne $p.ProcessId -and [bool]($r.Lines -match 'still frozen') -and [bool]($r.Lines -match 'was frozen')) "took $($r.Seconds)s; old PID $($p.ProcessId) -> new $newPid"

# T7 - dropped mount: kill rclone, watchdog should remount and say it dropped
Stop-Process -Id (WProc).ProcessId -Force; for ($i = 0; $i -lt 40 -and (Test-Path 'W:\'); $i++) { Start-Sleep -Milliseconds 250 }
$r = Run-Mount $W
Pass 'T7 dropped: remounted + "had dropped" toast' ((Test-Path 'W:\') -and [bool]($r.Lines -match 'had dropped')) "took $($r.Seconds)s"

# T8 - rclone fails to start: should report the reason fast
$r = Run-Mount @('-Letter','V:','-Remote','nosuchremote:','-CacheDir',"$Lab\cache-bad",'-LogName','rclone-wdtest-bad.log','-RcPort','5574','-NoToast')
$t = ($r.Lines -match 'TOAST') -replace '^.{29}',''
Pass 'T8 bad config: fails fast with reason' (($r.Seconds -lt 20) -and [bool]($r.Lines -match 'exited \(code')) "took $($r.Seconds)s; $t"

# T9 - health check
$h = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$S\Check-KoofrHealth.ps1" -NoToast
Pass 'T9 health check runs + writes report' ((Test-Path "$env:USERPROFILE\koofr-health.txt") -and [bool]($h -match 'Status:')) (($h -match 'Status:') -join '')

# --- cleanup ---
Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match '\smount\s+\S+\s+[WV]:(\s|$)' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Seconds 2
& rclone purge koofr:_rclone-lab --disable-http2
foreach ($d in "$Lab\cache-wd","$Lab\cache-bad") { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
Get-ChildItem $env:USERPROFILE -Filter 'rclone-wdtest*.log' | Move-Item -Destination "$Lab\logs" -Force
Get-ChildItem $State -Filter '*-[WV].flag' -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $State -Filter 'toast-fail-[WV].flag' -ErrorAction SilentlyContinue | Remove-Item -Force
if (Test-Path $SLog) { Move-Item $SLog "$Lab\logs\watchdog-test-script.log" -Force }
if (Test-Path "$SLog.pretest") { Move-Item "$SLog.pretest" $SLog -Force }
if (Test-Path "$env:USERPROFILE\koofr-health.txt") { Remove-Item "$env:USERPROFILE\koofr-health.txt" -Force }

$results | Format-Table -AutoSize -Wrap | Out-String -Width 220
$results | Export-Csv "$Lab\results\watchdog-tests.csv" -NoTypeInformation
"W: left mounted: $(Test-Path 'W:\')   Z: still up: $(Test-Path 'Z:\')"
