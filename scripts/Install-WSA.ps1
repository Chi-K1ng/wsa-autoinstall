<#
.SYNOPSIS
    One-click installer for Windows Subsystem for Android using MustardChef's
    WSABuilds, with Play Store, Magisk root, adb and .apk double-click set up.

.DESCRIPTION
    Runs interactively when given no arguments. Every choice is also a
    parameter, so the whole thing can run unattended.

.EXAMPLE
    .\Install-WSA.ps1
    Guided install with sensible defaults.

.EXAMPLE
    .\Install-WSA.ps1 -InstallDir D:\WSA -Unattended
    Root + Play Store, adb on PATH, PacMan registered, no prompts.

.NOTES
    Copyright (C) 2026  Chi-K1ng
    Licensed under the GNU Affero General Public License v3.0 or later.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [ValidateSet('Yes', 'No')][string]$Root      = 'Yes',
    [ValidateSet('Yes', 'No')][string]$GApps     = 'Yes',
    [ValidateSet('Yes', 'No')][string]$Amazon    = 'No',
    [ValidateSet('Yes', 'No')][string]$Adb       = 'Yes',
    [ValidateSet('Yes', 'No')][string]$Pacman    = 'Yes',
    [ValidateSet('Yes', 'No')][string]$DevMode   = 'Yes',
    [switch]$PacmanPortable,
    [switch]$Unattended,
    [switch]$KeepArchive
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WsaLib.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'WsaExtras.psm1') -Force

$Host.UI.RawUI.WindowTitle = 'WSA Auto-Install'

# Log everything to a file so a failure on someone else's machine can be
# reported by sending one file rather than retyping console output.
$script:LogPath = Join-Path $env:TEMP ("wsa-autoinstall-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $script:LogPath -Force | Out-Null } catch { $script:LogPath = $null }

function Stop-Log {
    if ($script:LogPath) { try { Stop-Transcript | Out-Null } catch { } }
}

# Any terminating error lands here: say what broke, where the log is, stop.
trap {
    Write-Host ''
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo.ScriptLineNumber) {
        Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    }
    if ($script:LogPath) {
        Write-Host ''
        Write-Host "  Full log: $script:LogPath" -ForegroundColor Yellow
    }
    Stop-Log
    exit 1
}

function Read-YesNo {
    param([string]$Question, [string]$Default = 'Yes')
    if ($Unattended) { return $Default -eq 'Yes' }
    $hint = if ($Default -eq 'Yes') { 'Y/n' } else { 'y/N' }
    $a = Read-Host "    $Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default -eq 'Yes' }
    $a -match '^(y|yes)$'
}

Write-Host @'

  Windows Subsystem for Android - automated installer
  Builds by MustardChef/WSABuilds  |  AGPL-3.0

'@ -ForegroundColor White

# Steps that always run, plus the optional ones the caller asked for. The
# count only drives the "[4/13]" labels, so an interactive answer that turns
# one off later just means the run ends a step or two early.
$steps = 9
foreach ($opt in @($DevMode, $Adb, $Root, $Pacman)) { if ($opt -eq 'Yes') { $steps++ } }
Start-WsaProgress -TotalSteps $steps
Write-Info "This run has about $steps steps. Nothing here is silent for long -"
Write-Info 'the slow ones (download, extract, install) report as they go.'

# ------------------------------------------------------------- 1. checks --

Write-Step 'Checking this PC'

if (-not (Test-Admin)) { throw 'Run Install-WSA.bat so it can elevate, or start PowerShell as administrator.' }
Write-Ok 'Running as administrator'

$hostInfo = Test-HostSupported
Write-Info "Windows build $($hostInfo.Build), $($hostInfo.Arch)"
if (-not $hostInfo.Supported) {
    throw "Build $($hostInfo.Build) is too old for WSA - Windows 10 19045 or Windows 11 22000 and up is required."
}
Write-Ok ('Supported ({0})' -f $(if ($hostInfo.IsWin11) { 'Windows 11' } else { 'Windows 10' }))

if (-not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    Write-Warn 'No hypervisor detected yet - normal before the first reboot, but if WSA fails to boot later, enable virtualisation (SVM / VT-x) in the BIOS.'
}

# -------------------------------------------------------------- 2. where --

Write-Step 'Choosing an install location'
Write-Info 'WSA runs from this folder permanently - moving or deleting it breaks the install.'

if (-not $InstallDir) {
    $default = 'C:\WSA'
    if ($Unattended) {
        $InstallDir = $default
    } else {
        $a = Read-Host "    Install folder [$default]"
        $InstallDir = if ([string]::IsNullOrWhiteSpace($a)) { $default } else { $a }
    }
}
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
$InstallDir = (Resolve-Path $InstallDir).Path

$free = (Get-PSDrive -Name (Split-Path $InstallDir -Qualifier).TrimEnd(':')).Free
if ($free -lt 8GB) {
    Write-Warn ('Only {0} GB free here; about 8 GB is needed for the download plus the extracted build.' -f [math]::Round($free / 1GB, 1))
    if (-not (Read-YesNo 'Continue anyway?' 'No')) { Stop-Log; exit 1 }
}
Write-Ok "Installing to $InstallDir"

# ------------------------------------------------------------- 3. choices --

if (-not $Unattended) {
    Write-Step 'What to include'
    $Root   = if (Read-YesNo 'Magisk root?'                    'Yes') { 'Yes' } else { 'No' }
    $GApps  = if (Read-YesNo 'Google Play Store?'              'Yes') { 'Yes' } else { 'No' }
    $Amazon = if (Read-YesNo 'Amazon Appstore?'                'No')  { 'Yes' } else { 'No' }
    $Adb    = if (Read-YesNo 'Install adb and add it to PATH?' 'Yes') { 'Yes' } else { 'No' }
    $Pacman = if (Read-YesNo 'Install APKs by double-click (WSA PacMan)?' 'Yes') { 'Yes' } else { 'No' }
}

# ------------------------------------------------------------ 4. prereqs --

Write-Step 'Enabling Windows prerequisites'
$needReboot = Enable-WsaPrereq
if ($needReboot) {
    Write-Warn 'VirtualMachinePlatform was just enabled and Windows must restart before WSA can run.'
    Write-Info 'Restart, then run this installer again - it resumes from the download.'
    Stop-Log
    if (Read-YesNo 'Restart now?' 'No') { Restart-Computer -Force }
    exit 0
}

# ------------------------------------------------------------ 5. release --

Write-Step 'Finding the newest build'
$release = Get-WsaRelease -IsWin11 $hostInfo.IsWin11 -Arm64 $hostInfo.Arm64
Write-Ok "Release $($release.tag_name)"

$variants = Get-WsaVariant -Release $release
$variant  = Select-WsaVariant -Variants $variants `
                -WantRoot ($Root -eq 'Yes') -WantGApps ($GApps -eq 'Yes') -WantAmazon ($Amazon -eq 'Yes')
Write-Ok "Variant: $($variant.Label)  ($($variant.SizeMB) MB)"
Write-Info $variant.Name

# ----------------------------------------------------------- 6. download --

Write-Step 'Downloading'
$archive = Join-Path $InstallDir $variant.Name
Invoke-WsaDownload -Url $variant.Url -Destination $archive -ExpectedSize $variant.Size

# ------------------------------------------------------------ 7. extract --

Write-Step 'Extracting'
$packageDir = Expand-Wsa7z -Archive $archive -Destination $InstallDir

# ------------------------------------------------------------ 8. install --

Write-Step 'Installing the WSA package'
Install-WsaPackage -PackageDir $packageDir

if (-not $KeepArchive) {
    Remove-Item $archive -Force -ErrorAction SilentlyContinue
    Write-Info 'Removed the downloaded archive (pass -KeepArchive to keep it)'
}

# ------------------------------------------------------------ 9. devmode --

if ($DevMode -eq 'Yes') {
    Write-Step 'Turning on Developer mode'
    try {
        Set-WsaDeveloperMode -Enabled $true
    } catch {
        Write-Warn "Could not set Developer mode automatically: $($_.Exception.Message)"
        Write-Info 'Turn it on by hand in the WSA Settings app, under Advanced settings.'
    }
}

# --------------------------------------------------------------- 10. boot --

Write-Step 'Starting WSA for the first time'
Start-Wsa

$adbExe = $null
if ($Adb -eq 'Yes') {
    Write-Step 'Setting up adb'
    $adbExe = Install-PlatformTools -Destination $InstallDir -AddToPath
    $connected = Connect-Wsa -Adb $adbExe
    if (-not $connected) {
        Write-Info 'Accept the RSA prompt in the WSA window, then run:'
        Write-Info "  `"$adbExe`" connect 127.0.0.1:58526"
    }
}

# --------------------------------------------------------------- 11. root --

if ($Root -eq 'Yes' -and $adbExe) {
    Write-Step 'Granting root to the adb shell'
    Write-Info 'Keep the WSA window visible - input cannot be injected into a hidden window.'
    try {
        Grant-WsaRoot -Adb $adbExe | Out-Null
    } catch {
        Write-Warn "Automatic grant failed: $($_.Exception.Message)"
        Write-Info 'Open Magisk > Superuser and enable Shell by hand.'
    }
}

# ------------------------------------------------------------- 12. pacman --

if ($Pacman -eq 'Yes') {
    Write-Step 'Setting up APK double-click installs'
    try {
        if ($PacmanPortable) {
            Install-WsaPacman -Portable -PortableDir (Join-Path $InstallDir 'wsa-pacman')
        } else {
            Install-WsaPacman
        }
    } catch {
        Write-Warn "WSA PacMan setup failed: $($_.Exception.Message)"
        Write-Info "You can still install APKs with: adb -s 127.0.0.1:58526 install app.apk"
    }
}

# ------------------------------------------------------------- 13. report --

Write-Step 'Done'
Write-Host ''
Write-Info "Install folder   $InstallDir   (do not move it)"
Write-Info "Developer mode   $(try { Get-WsaDeveloperMode } catch { 'unknown' })"
if ($adbExe) {
    $state = (& $adbExe -s 127.0.0.1:58526 get-state 2>&1) -join ''
    Write-Info "adb              $state  at 127.0.0.1:58526"
    Write-Info "Root             $(Test-WsaRoot -Adb $adbExe)"
    Write-Host ''
    Write-Info 'This PC may have more than one adb device attached, so target WSA explicitly:'
    Write-Info '  adb -s 127.0.0.1:58526 install yourapp.apk'
}
Write-Host ''
Write-Host ('  WSA is ready - {0} from start to finish.' -f (Format-Span (Get-WsaElapsed))) -ForegroundColor Green
if ($script:LogPath) { Write-Info "Log: $script:LogPath" }
Write-Host ''
Stop-Log
