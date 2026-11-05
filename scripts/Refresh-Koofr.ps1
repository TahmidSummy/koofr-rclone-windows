<#
    Refresh-Koofr.ps1 - make the Koofr drive show changes made elsewhere (phone, website) right now.
    Koofr can't tell rclone about changes, so the drive trusts folder listings for up to an hour
    (--dir-cache-time 1h). This tells the running rclone to forget its cached listings; folders are
    re-read from Koofr the next time you open them (press F5 in an Explorer window that's already open).
    Run from the "Refresh Koofr" desktop shortcut that Install-KoofrMount.ps1 creates.
#>
param([int]$RcPort = 5572, [string]$Letter = 'Z:', [switch]$NoToast)
. (Join-Path $PSScriptRoot 'KoofrCommon.ps1')
$script:KoofrNoToast = [bool]$NoToast

try {
    $null = Invoke-KoofrRc -Command 'vfs/forget' -Port $RcPort                  # drop every cached folder listing
    $null = Invoke-KoofrRc -Command 'vfs/refresh' -Port $RcPort -TimeoutSec 60  # re-read the top level straight away
    Write-KLog "refresh: folder listings cleared for $Letter"
    Show-Toast -Title 'Koofr refreshed' -Body "$Letter now shows the latest from Koofr. Press F5 in any open Explorer window."
} catch {
    Write-KLog "refresh failed: $($_.Exception.Message)" 'ERROR'
    Show-Toast -Title 'Koofr refresh failed' -Body "Couldn't reach rclone for $Letter. Is the drive mounted? ($($_.Exception.Message))"
}
