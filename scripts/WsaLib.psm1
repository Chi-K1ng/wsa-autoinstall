# wsa-autoinstall - shared helpers
# Copyright (C) 2026  Chi-K1ng
# Licensed under the GNU Affero General Public License v3.0 or later.

$script:PkgName   = 'MicrosoftCorporationII.WindowsSubsystemForAndroid'
$script:PFN       = 'MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$script:AppAumid  = "shell:AppsFolder\$script:PFN!App"
$script:AdbTarget = '127.0.0.1:58526'

# -------------------------------------------------------------- progress --
#
# Everything the user sees goes through here. Two rules shape it:
#
#   * Steps are numbered "[4/13]" and timed, so a long silent stretch still
#     reads as progress rather than a hang.
#   * Live single-line updates are written with [Console]::Write, which
#     Start-Transcript does not capture. A 700 MB download would otherwise
#     become thousands of near-identical lines in the log.

$script:StepNo    = 0
$script:StepTotal = 0
$script:StepStart = $null
$script:RunStart  = $null
$script:StatusOn  = $false

function Start-WsaProgress {
    param([int]$TotalSteps = 0)
    $script:StepNo    = 0
    $script:StepTotal = $TotalSteps
    $script:StepStart = $null
    $script:RunStart  = Get-Date
}

function Get-WsaElapsed {
    if (-not $script:RunStart) { return [TimeSpan]::Zero }
    (Get-Date) - $script:RunStart
}

function Format-Span {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) { '{0}h {1:00}m' -f [int]$Span.TotalHours, $Span.Minutes }
    else { '{0}m {1:00}s' -f [int]$Span.TotalMinutes, $Span.Seconds }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB)     { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) }
    else                    { '{0:N0} KB' -f ($Bytes / 1KB) }
}

function Test-CanDrawStatus {
    # No console (output redirected or piped to a file) means no cursor to rewind.
    try { -not [Console]::IsOutputRedirected } catch { $false }
}

function Get-ConsoleWidth {
    try { [Math]::Max(40, [Console]::WindowWidth - 1) } catch { 79 }
}

function Write-Status {
    # Overwrites the current line in place; silent when there is no console.
    param([string]$Text)
    if (-not (Test-CanDrawStatus)) { return }
    $w    = Get-ConsoleWidth
    $line = "    $Text"
    if ($line.Length -gt $w) { $line = $line.Substring(0, $w) }
    [Console]::Write("`r" + $line.PadRight($w))
    $script:StatusOn = $true
}

function Complete-Status {
    # Wipes the live line so the next real message starts on a clean row.
    if ($script:StatusOn -and (Test-CanDrawStatus)) {
        [Console]::Write("`r" + (' ' * (Get-ConsoleWidth)) + "`r")
    }
    $script:StatusOn = $false
}

function Write-Step {
    param([string]$Text)
    Complete-Status
    if ($script:StepStart) {
        Write-Host ('    done in {0}' -f (Format-Span ((Get-Date) - $script:StepStart))) -ForegroundColor DarkGray
    }
    $script:StepNo++
    $tag = if ($script:StepTotal -gt 0) { '[{0}/{1}]' -f $script:StepNo, $script:StepTotal } else { '==>' }
    Write-Host ''
    Write-Host "  $tag $Text" -ForegroundColor Cyan
    $script:StepStart = Get-Date
}

function Write-Ok   { param([string]$Text) Complete-Status; Write-Host "    [ok] $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Complete-Status; Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Complete-Status; Write-Host "    $Text"      -ForegroundColor Gray }

function Wait-WithStatus {
    <#
      Polls until $Test returns true, showing a live countdown so a two minute
      wait does not look like a freeze. Returns whether it ended up true.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Test,
        [Parameter(Mandatory)][string]$Message,
        [int]$TimeoutSeconds  = 120,
        [int]$IntervalSeconds = 3
    )
    $sw   = [Diagnostics.Stopwatch]::StartNew()
    $spin = [char[]]'|/-\'
    $i    = 0
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Test) { Complete-Status; return $true }
        Write-Status ('{0} {1}  ({2} of {3}s)' -f $spin[$i++ % $spin.Length], $Message,
                      (Format-Span $sw.Elapsed), $TimeoutSeconds)
        Start-Sleep -Seconds $IntervalSeconds
    }
    Complete-Status
    [bool](& $Test)
}

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

# ----------------------------------------------------------------- vendor --
#
# The small third-party helpers are committed under vendor/, so a plain
# "Download ZIP" of the repo installs with no network at all. Every fetch
# looks here first and only falls back to the internet when nothing is
# bundled, which also means deleting a vendored file just costs a download.

function Get-VendorDir {
    # scripts/ normally sits one level under the repo root, but a copied-out
    # scripts/ folder with its own vendor/ works too - the layout is not
    # load-bearing.
    foreach ($dir in @((Join-Path (Split-Path $PSScriptRoot -Parent) 'vendor'),
                       (Join-Path $PSScriptRoot 'vendor'))) {
        if (Test-Path -LiteralPath $dir) { return (Resolve-Path -LiteralPath $dir).Path }
    }
    $null
}

function Get-VendorFile {
    # Newest match for $Pattern, or $null when nothing is bundled.
    param([Parameter(Mandatory)][string]$Pattern)
    $dir = Get-VendorDir
    if (-not $dir) { return $null }
    $hit = Get-ChildItem -LiteralPath $dir -Filter $Pattern -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { $hit.FullName } else { $null }
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

function ConvertTo-WsaVariant {
    # Turns one cryptic WSABuilds filename into something choosable. Release
    # assets and a .7z already sitting on disk both come through here, so an
    # offline install describes itself exactly like a downloaded one.
    param([Parameter(Mandatory)][string]$Name,
          [string]$Url,
          [long]$Size = 0,
          [string]$LocalPath)

    # Every flag below is read from a token in the name, and each one is read
    # from a token's *absence* as much as its presence - so a file someone
    # renamed to wsa.7z parses as "no root, Play Store, Amazon" with no
    # evidence for any of it. Worse, "no root" would then turn off the root
    # grant for a build that does have Magisk. A name carrying none of the
    # tokens is therefore marked unknown, and callers leave the user's own
    # answers alone rather than trusting this.
    $known = [bool]($Name -match 'magisk|GApps|NoAmazon')

    [pscustomobject]@{
        Name      = $Name
        Url       = $Url
        LocalPath = $LocalPath
        Size      = $Size
        SizeMB    = [math]::Round($Size / 1MB)
        Known     = $known
        Root      = [bool]($Name -match 'magisk')
        Channel   = if ($Name -match '-(stable|canary)-') { $Matches[1] } else { $null }
        GApps     = [bool]($Name -notmatch 'NoGApps')
        Amazon    = [bool]($Name -notmatch 'NoAmazon')
        Label     = if (-not $known) { 'contents not stated in the filename' } else {
            (@(
                if ($Name -match 'magisk')      { 'Magisk root' } else { 'no root' }
                if ($Name -notmatch 'NoGApps')  { 'Play Store' }  else { 'no Play Store' }
                if ($Name -notmatch 'NoAmazon') { 'Amazon Appstore' }
            ) | Where-Object { $_ }) -join ' + '
        }
    }
}

function Get-WsaVariant {
    param($Release)
    $Release.assets | Where-Object { $_.name -like '*.7z' } | ForEach-Object {
        ConvertTo-WsaVariant -Name $_.name -Url $_.browser_download_url -Size ([long]$_.size)
    }
}

function Find-LocalWsaArchive {
    <#
      Finds a WSABuilds .7z already on this PC, which skips both the release
      lookup and the 700 MB download - the whole point of the offline path.
      An explicit -Path wins; otherwise vendor/, the repo root and the install
      folder are searched, largest file first so a part-downloaded leftover
      does not beat the real one.
    #>
    param([string]$Path, [string]$InstallDir)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "No archive at $Path." }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $roots = @((Get-VendorDir), (Split-Path $PSScriptRoot -Parent), $InstallDir)
    foreach ($r in ($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        $hit = Get-ChildItem -LiteralPath $r -Filter 'WSA_*.7z' -File -ErrorAction SilentlyContinue |
               Sort-Object Length -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $null
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

    if ($ExpectedSize -gt 0) { Write-Info ('Size {0}' -f (Format-Bytes $ExpectedSize)) }
    Write-Info "To   $Destination"
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # curl.exe ships with Win10 1803+, resumes cleanly with -C -, and draws its
    # own percent/speed/ETA meter on stderr - which the transcript ignores.
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        Write-Info 'Ctrl+C is safe here - rerunning resumes where it stopped'
        Write-Host ''
        & $curl -L --fail --retry 3 --retry-delay 2 -C - -o $Destination $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit $LASTEXITCODE)." }
        Write-Host ''
    } else {
        Write-Info 'Downloading (no curl.exe on this host, so no live meter)'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }

    $got  = (Get-Item $Destination).Length
    $rate = if ($sw.Elapsed.TotalSeconds -gt 1) { ' at {0}/s' -f (Format-Bytes ($got / $sw.Elapsed.TotalSeconds)) } else { '' }
    Write-Ok ('Downloaded {0} in {1}{2}' -f (Format-Bytes $got), (Format-Span $sw.Elapsed), $rate)
}

# ---------------------------------------------------------------- extract --

function Measure-TreeBytes {
    # Best effort: files are appearing underneath this while we count them, so
    # errors are swallowed and the number is only ever used for display.
    param([string]$Path)
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($sum) { [double]$sum } else { [double]0 }
    } catch { [double]0 }
}

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
        $exe  = $tar
        $eArgs = @('-xf', $Archive, '-C', $Destination)
        $what = 'bsdtar'
    } else {
        Write-Warn 'Built-in tar cannot read .7z on this build; using 7zr.exe instead'
        $7zr = Get-VendorFile '7zr.exe'
        if ($7zr) {
            Write-Info 'Using the bundled 7zr.exe'
        } else {
            $7zr = Join-Path $env:TEMP '7zr.exe'
            if (-not (Test-Path $7zr)) {
                Write-Info 'Downloading 7zr.exe from 7-zip.org'
                Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile $7zr -UseBasicParsing
            }
        }
        $exe  = $7zr
        $eArgs = @('x', $Archive, "-o$Destination", '-y', '-bso0')
        $what = '7zr'
    }

    # Neither extractor reports progress usefully, and this is several minutes
    # of writing. Run it as a child process and measure the tree as it grows.
    $baseline = Measure-TreeBytes $Destination
    $proc = Start-Process -FilePath $exe -ArgumentList $eArgs -NoNewWindow -PassThru
    # Touching Handle caches it, without which ExitCode reads back empty once
    # the process is gone and every extraction looks like a failure.
    $null = $proc.Handle
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
        $written = [Math]::Max([double]0, (Measure-TreeBytes $Destination) - $baseline)
        Write-Status ('Extracting with {0} - {1} written, {2} elapsed' -f $what, (Format-Bytes $written), (Format-Span $sw.Elapsed))
        Start-Sleep -Milliseconds 1500
    }
    $proc.WaitForExit()
    Complete-Status
    if ($proc.ExitCode -ne 0) { throw "Extraction failed ($what exit $($proc.ExitCode))." }
    $total = [Math]::Max([double]0, (Measure-TreeBytes $Destination) - $baseline)
    Write-Ok ('Unpacked {0} in {1}' -f (Format-Bytes $total), (Format-Span $sw.Elapsed))

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

    Write-Info 'Handing over to the build''s own Install.ps1 - this takes a few minutes'
    Write-Info 'Everything between the rules below is upstream output, not ours.'
    Write-Host ('    ' + ('-' * 58)) -ForegroundColor DarkGray
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $PackageDir
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
    } finally {
        Pop-Location
    }
    Write-Host ('    ' + ('-' * 58)) -ForegroundColor DarkGray
    Write-Info ('Upstream installer finished in {0}' -f (Format-Span $sw.Elapsed))

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

    Write-Info 'Launching the WSA app, which is what actually boots the Android VM'
    Start-Process $script:AppAumid

    $up = Wait-WithStatus -Message 'Booting the Android VM' -TimeoutSeconds $TimeoutSeconds `
                          -Test { [bool](Get-Process WsaService -ErrorAction SilentlyContinue) }
    if (-not $up) { throw "WSA did not start within $TimeoutSeconds seconds." }
    Write-Ok 'WSA VM is running'

    # adbd binds a moment after WsaService appears; a never-true test just
    # burns the clock with something on screen.
    $null = Wait-WithStatus -Message 'Letting adbd bind' -TimeoutSeconds 10 -IntervalSeconds 1 -Test { $false }
}

function Install-PlatformTools {
    param([Parameter(Mandatory)][string]$Destination, [switch]$AddToPath)

    $adb = Join-Path $Destination 'platform-tools\adb.exe'
    if (Test-Path $adb) {
        Write-Ok 'platform-tools already present'
    } else {
        $bundled = Get-VendorFile 'platform-tools-*.zip'
        if ($bundled) {
            $zip = $bundled
            Write-Info 'Using the bundled platform-tools'
        } else {
            $zip = Join-Path $env:TEMP 'platform-tools.zip'
            Write-Info 'Downloading Google platform-tools'
            Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
                -OutFile $zip -UseBasicParsing
        }
        Expand-Archive -Path $zip -DestinationPath $Destination -Force
        # Only a temp copy is ours to delete; the vendored zip stays put.
        if (-not $bundled) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
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
        Write-Status ('Connecting to {0} - attempt {1} of {2}' -f $script:AdbTarget, $i, $Retries)
        & $Adb connect $script:AdbTarget | Out-Null
        Start-Sleep -Seconds 3
        $state = (& $Adb -s $script:AdbTarget get-state 2>&1) -join ''
        if ($state -match 'device') { Write-Ok "adb connected to $script:AdbTarget"; return $true }
        if ($state -match 'unauthorized') {
            Write-Warn 'adb is unauthorized - accept the RSA prompt in the WSA window'
        }
        Start-Sleep -Seconds 3
    }
    Complete-Status
    Write-Warn "Could not reach an authorized adb state at $script:AdbTarget"
    $false
}
