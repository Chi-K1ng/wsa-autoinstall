# wsa-autoinstall - shared helpers
# Copyright (C) 2026  Chi-K1ng
# Licensed under the GNU Affero General Public License v3.0 or later.

$script:PkgName   = 'MicrosoftCorporationII.WindowsSubsystemForAndroid'
$script:PFN       = 'MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$script:AppAumid  = "shell:AppsFolder\$script:PFN!App"
$script:AdbTarget = '127.0.0.1:58526'

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    [ok] $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "    $Text"      -ForegroundColor Gray }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# ---------------------------------------------------------------- prereqs --

function Test-HostSupported {
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    [pscustomobject]@{
        Build     = $build
        Arch      = $env:PROCESSOR_ARCHITECTURE
        IsWin11   = $build -ge 22000
        Arm64     = $env:PROCESSOR_ARCHITECTURE -eq 'ARM64'
        # WSA requires Win10 19045+ / Win11 22000+
        Supported = $build -ge 19045
    }
}

function Enable-WsaPrereq {
    # Sideloading unlock, required by Add-AppxPackage -Register
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'AllowDevelopmentWithoutDevLicense' `
        -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Ok 'Sideloading unlocked (AllowDevelopmentWithoutDevLicense=1)'

    # PowerShell installed as MSIX cannot call the DISM cmdlets directly
    if ($PSHOME -like '*8wekyb3d8bbwe*') {
        Import-Module DISM -UseWindowsPowerShell -WarningAction SilentlyContinue
    }

    $needReboot = $false
    $state = (Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform').State
    if ($state -ne 'Enabled') {
        Write-Info 'Enabling Windows feature: VirtualMachinePlatform'
        $r = Enable-WindowsOptionalFeature -Online -NoRestart -FeatureName 'VirtualMachinePlatform'
        if ($r.RestartNeeded) { $needReboot = $true }
    } else {
        Write-Ok 'VirtualMachinePlatform already enabled'
    }
    $needReboot
}

# --------------------------------------------------------------- releases --

function Get-WsaRelease {
    # Resolved live from the GitHub API so the installer never goes stale.
    param(
        [string]$Repo = 'MustardChef/WSABuilds',
        [bool]$IsWin11 = $true,
        [bool]$Arm64 = $false
    )
    $headers = @{ 'User-Agent' = 'wsa-autoinstall'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }

    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases" -Headers $headers
    $osTag = if ($IsWin11) { 'Windows_11' } else { 'Windows_10' }

    $want = $releases |
        Where-Object { $_.tag_name -like "$osTag*" -and (($_.tag_name -like '*_arm64') -eq $Arm64) } |
        Select-Object -First 1

    if (-not $want) { throw "No WSABuilds release found for $osTag (arm64=$Arm64)." }
    $want
}

function Get-WsaVariant {
    # Turns the cryptic asset names into something choosable.
    param($Release)
    $Release.assets | Where-Object { $_.name -like '*.7z' } | ForEach-Object {
        $n = $_.name
        [pscustomobject]@{
            Name    = $n
            Url     = $_.browser_download_url
            Size    = [long]$_.size
            SizeMB  = [math]::Round($_.size / 1MB)
            Root    = [bool]($n -match 'magisk')
            Channel = if ($n -match '-(stable|canary)-') { $Matches[1] } else { $null }
            GApps   = [bool]($n -notmatch 'NoGApps')
            Amazon  = [bool]($n -notmatch 'NoAmazon')
            Label   = (@(
                if ($n -match 'magisk')      { 'Magisk root' } else { 'no root' }
                if ($n -notmatch 'NoGApps')  { 'Play Store' }  else { 'no Play Store' }
                if ($n -notmatch 'NoAmazon') { 'Amazon Appstore' }
            ) | Where-Object { $_ }) -join ' + '
        }
    }
}

function Select-WsaVariant {
    <#
      Root and Play Store are hard requirements. Beyond those, a stable Magisk
      channel outranks matching the Amazon preference: upstream does not ship
      every combination, and "root + Play Store, no Amazon" often exists only
      as a canary build. Shipping canary to get rid of an extra store is a bad
      trade, so Amazon is the first preference to give way.
    #>
    param($Variants, [bool]$WantRoot = $true, [bool]$WantGApps = $true, [bool]$WantAmazon = $false)

    $candidates = $Variants | Where-Object { $_.Root -eq $WantRoot -and $_.GApps -eq $WantGApps }
    if (-not $candidates) { throw 'No build matches the requested combination of options.' }

    $pick = $candidates | Sort-Object `
        @{ Expression = { $_.Root -and $_.Channel -ne 'stable' } },  # stable first
        @{ Expression = { $_.Amazon -ne $WantAmazon } },             # then Amazon preference
        @{ Expression = { $_.Size } } |                              # then the smaller download
        Select-Object -First 1

    if ($pick.Amazon -ne $WantAmazon) {
        $word = if ($pick.Amazon) { 'includes' } else { 'omits' }
        Write-Warn "No stable build matched your Amazon Appstore choice, so this one $word it."
    }
    $pick
}

# --------------------------------------------------------------- download --

function Invoke-WsaDownload {
    # Resumable; a complete file already on disk is reused.
    param([Parameter(Mandatory)][string]$Url,
          [Parameter(Mandatory)][string]$Destination,
          [long]$ExpectedSize = 0)

    $dir = Split-Path $Destination -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ((Test-Path $Destination) -and $ExpectedSize -gt 0) {
        $have = (Get-Item $Destination).Length
        if ($have -eq $ExpectedSize) {
            Write-Ok "Already downloaded ($([math]::Round($have / 1MB)) MB)"
            return
        }
        if ($have -gt $ExpectedSize) { Remove-Item $Destination -Force }
    }

    # curl.exe ships with Win10 1803+ and resumes cleanly with -C -
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        Write-Info 'Downloading - Ctrl+C is safe, rerunning resumes where it stopped'
        & $curl -L --fail --retry 3 --retry-delay 2 -C - -o $Destination $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit $LASTEXITCODE)." }
    } else {
        Write-Info 'Downloading'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
    Write-Ok "Downloaded $([math]::Round((Get-Item $Destination).Length / 1MB)) MB"
}

# ---------------------------------------------------------------- extract --

function Expand-Wsa7z {
    # Windows' own bsdtar reads .7z when libarchive is 3.4+, which covers
    # current Win10/11. Older hosts fall back to 7zr.exe.
    param([Parameter(Mandatory)][string]$Archive,
          [Parameter(Mandatory)][string]$Destination)

    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $canTar = $false
    if (Test-Path $tar) {
        & $tar -tf $Archive 2>&1 | Out-Null
        $canTar = ($LASTEXITCODE -eq 0)
    }

    if ($canTar) {
        Write-Info 'Extracting with the built-in bsdtar'
        & $tar -xf $Archive -C $Destination
        if ($LASTEXITCODE -ne 0) { throw "Extraction failed (tar exit $LASTEXITCODE)." }
    } else {
        Write-Warn 'Built-in tar cannot read .7z on this build; fetching 7zr.exe'
        $7zr = Join-Path $env:TEMP '7zr.exe'
        if (-not (Test-Path $7zr)) {
            Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile $7zr -UseBasicParsing
        }
        & $7zr x $Archive "-o$Destination" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Extraction failed (7zr exit $LASTEXITCODE)." }
    }

    $root = Get-ChildItem $Destination -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'AppxManifest.xml') } |
        Select-Object -First 1
    if (-not $root) { throw 'Extracted folder does not contain AppxManifest.xml.' }

    Write-Ok "Extracted to $($root.FullName)"
    $root.FullName
}

# ---------------------------------------------------------------- install --

function Install-WsaPackage {
    # Defers to the Install.ps1 that ships inside the build itself.
    param([Parameter(Mandatory)][string]$PackageDir)

    $installer = Join-Path $PackageDir 'Install.ps1'
    if (-not (Test-Path $installer)) { throw "Install.ps1 is missing from $PackageDir." }

    $existing = Get-AppxPackage -Name $script:PkgName -ErrorAction SilentlyContinue
    if ($existing -and -not $existing.IsDevelopmentMode) {
        Write-Warn 'A Store-installed WSA is present; removing it first'
        Remove-AppxPackage -Package $existing.PackageFullName
    }

    Write-Info 'Running the build''s own Install.ps1 - this takes a few minutes'
    Push-Location $PackageDir
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
    } finally {
        Pop-Location
    }

    $pkg = Get-AppxPackage -Name $script:PkgName -ErrorAction SilentlyContinue
    if (-not $pkg) { throw 'The WSA package is not registered after install.' }
    Write-Ok "Registered $($pkg.Name) $($pkg.Version)"
}

# --------------------------------------------------------------- dev mode --

function Set-WsaDeveloperMode {
    <#
      WSA persists its Developer mode toggle as a UWP LocalSettings value.
      ApplicationDataManager.CreateForPackageFamily reaches another package's
      settings store from a full-trust process, so this needs no admin rights,
      no UI and no shutdown. PowerShell cannot do an indexed set on a WinRT
      property set, hence the reflected set_Item call.
    #>
    param([bool]$Enabled = $true)

    $null = [Windows.Management.Core.ApplicationDataManager, Windows.Management, ContentType = WindowsRuntime]
    $settings = [Windows.Management.Core.ApplicationDataManager]::CreateForPackageFamily($script:PFN).LocalSettings
    $setItem  = [System.Collections.Generic.IDictionary[string, object]].GetMethod('set_Item')

    $setItem.Invoke($settings.Values, [object[]]@('DeveloperModeEnabled', [object]$Enabled))

    $now = ([Windows.Management.Core.ApplicationDataManager]::CreateForPackageFamily($script:PFN)).LocalSettings.Values['DeveloperModeEnabled']
    if ($now -ne $Enabled) { throw "Failed to set Developer mode (still '$now')." }
    Write-Ok "Developer mode set to $Enabled"
}

function Get-WsaDeveloperMode {
    $null = [Windows.Management.Core.ApplicationDataManager, Windows.Management, ContentType = WindowsRuntime]
    ([Windows.Management.Core.ApplicationDataManager]::CreateForPackageFamily($script:PFN)).LocalSettings.Values['DeveloperModeEnabled']
}

# ------------------------------------------------------------- boot / adb --

function Start-Wsa {
    <#
      The ADB port only listens once the Android VM is actually running, and
      the !SettingsApp alias opens Settings without booting it - !App is the
      one that starts the VM.
    #>
    param([int]$TimeoutSeconds = 120)

    Start-Process $script:AppAumid
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        $svc = Get-Process WsaService -ErrorAction SilentlyContinue
    } while (-not $svc -and (Get-Date) -lt $deadline)

    if (-not $svc) { throw "WSA did not start within $TimeoutSeconds seconds." }
    Write-Ok 'WSA VM is running'
    Start-Sleep -Seconds 10   # adbd binds a moment after WsaService appears
}

function Install-PlatformTools {
    param([Parameter(Mandatory)][string]$Destination, [switch]$AddToPath)

    $adb = Join-Path $Destination 'platform-tools\adb.exe'
    if (Test-Path $adb) {
        Write-Ok 'platform-tools already present'
    } else {
        $zip = Join-Path $env:TEMP 'platform-tools.zip'
        Write-Info 'Downloading Google platform-tools'
        Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
            -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $Destination -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $adb)) { throw 'platform-tools did not extract correctly.' }
        Write-Ok "Installed platform-tools to $Destination"
    }

    if ($AddToPath) {
        $dir  = Split-Path $adb -Parent
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($user -notlike "*$dir*") {
            [Environment]::SetEnvironmentVariable('Path', "$user;$dir", 'User')
            Write-Ok 'Added adb to the user PATH (new terminals will see it)'
        } else {
            Write-Ok 'adb already on the user PATH'
        }
        $env:Path = "$env:Path;$dir"
    }
    $adb
}

function Connect-Wsa {
    param([Parameter(Mandatory)][string]$Adb, [int]$Retries = 6)

    for ($i = 1; $i -le $Retries; $i++) {
        & $Adb connect $script:AdbTarget | Out-Null
        Start-Sleep -Seconds 3
        $state = (& $Adb -s $script:AdbTarget get-state 2>&1) -join ''
        if ($state -match 'device') { Write-Ok "adb connected to $script:AdbTarget"; return $true }
        if ($state -match 'unauthorized') {
            Write-Warn 'adb is unauthorized - accept the RSA prompt in the WSA window'
        }
        Start-Sleep -Seconds 3
    }
    Write-Warn "Could not reach an authorized adb state at $script:AdbTarget"
    $false
}
