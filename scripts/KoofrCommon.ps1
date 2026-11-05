<#
    KoofrCommon.ps1 - shared helpers for Mount-Koofr.ps1, Refresh-Koofr.ps1 and Check-KoofrHealth.ps1.
    Dot-source it:  . (Join-Path $PSScriptRoot 'KoofrCommon.ps1')
    Works in Windows PowerShell 5.1 (powershell.exe) and PowerShell 7.
#>

$KoofrStateDir  = Join-Path $env:LOCALAPPDATA 'KoofrMount'      # private to your user account
$KoofrScriptLog = Join-Path $env:USERPROFILE 'koofr-mount-script.log'
if (-not (Test-Path -LiteralPath $KoofrStateDir)) { New-Item -ItemType Directory -Path $KoofrStateDir -Force | Out-Null }
if (-not (Get-Variable -Name KoofrNoToast -Scope Script -ErrorAction SilentlyContinue)) { $script:KoofrNoToast = $false }

# --- Script log: one line per thing the scripts actually do (kept under ~1 MB) ---
function Write-KLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} {1,-5} [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $PID, $Message
    Write-Output $line
    try {
        if ((Test-Path -LiteralPath $KoofrScriptLog) -and (Get-Item -LiteralPath $KoofrScriptLog).Length -gt 1MB) {
            Move-Item -LiteralPath $KoofrScriptLog -Destination "$KoofrScriptLog.old" -Force
        }
        Add-Content -LiteralPath $KoofrScriptLog -Value $line -Encoding UTF8
    } catch { }
}

# --- Notifications (native Windows toasts, no modules needed) ---
$ToastAppId   = 'Koofr.MountScript'            # our own notification identity
$ToastAppName = 'Koofr Mount'                  # how it shows in Settings > Notifications

function Register-ToastAppId {
    $key = "HKCU:\Software\Classes\AppUserModelId\$ToastAppId"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'DisplayName' -Value $ToastAppName -PropertyType String -Force | Out-Null
}

function Show-Toast {
    param([string]$Title, [string]$Body)
    Write-KLog "TOAST: $Title - $Body"
    if ($script:KoofrNoToast) { return }
    try {
        Register-ToastAppId
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.UI.Notifications.ToastNotification,        Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,     ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        $nodes.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null
        $nodes.Item(1).AppendChild($xml.CreateTextNode($Body))  | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
    } catch {
        Write-KLog "Toast failed ($($_.Exception.Message))" 'WARN'
    }
}

# Same as Show-Toast, but at most once per $Minutes for the same $Key
# (the watchdog runs every 15 min, so an ongoing problem shouldn't pop up every 15 min).
function Show-ToastThrottled {
    param([string]$Key, [int]$Minutes, [string]$Title, [string]$Body)
    $flag = Join-Path $KoofrStateDir "toast-$Key.flag"
    if ((Test-Path -LiteralPath $flag) -and ((Get-Date) - (Get-Item -LiteralPath $flag).LastWriteTime).TotalMinutes -lt $Minutes) {
        Write-KLog "toast '$Key' suppressed (already shown in the last $Minutes min): $Title - $Body"
        return
    }
    Set-Content -LiteralPath $flag -Value (Get-Date -Format o)
    Show-Toast -Title $Title -Body $Body
}

# --- rclone remote control (used by the refresh shortcut) ---
# Random password created once, stored in your private LocalAppData folder.
function Get-RcCredential {
    $f = Join-Path $KoofrStateDir 'rc.pass'
    if (-not (Test-Path -LiteralPath $f)) {
        $bytes = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        Set-Content -LiteralPath $f -Value ([Convert]::ToBase64String($bytes) -replace '[+/=]', 'x') -NoNewline
    }
    [pscustomobject]@{ User = 'koofr'; Pass = (Get-Content -LiteralPath $f -Raw).Trim() }
}

function Invoke-KoofrRc {
    param([string]$Command, [hashtable]$Params = @{}, [int]$Port = 5572, [int]$TimeoutSec = 30)
    $c = Get-RcCredential
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($c.User):$($c.Pass)"))
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/$Command" -Headers @{ Authorization = "Basic $auth" } `
        -ContentType 'application/json' -Body ($Params | ConvertTo-Json -Compress) -TimeoutSec $TimeoutSec
}
