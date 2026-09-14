# wsa-autoinstall - root grant and APK handler setup
# Copyright (C) 2026  Chi-K1ng
# Licensed under the GNU Affero General Public License v3.0 or later.

$script:AdbTarget = '127.0.0.1:58526'

# The reporting helpers live in WsaLib. Defining a second copy here would
# shadow them depending on import order, and the step counter would reset.
Import-Module (Join-Path $PSScriptRoot 'WsaLib.psm1') -Force -DisableNameChecking

# ------------------------------------------------------------ ui plumbing --

function Get-UiDump {
    <#
      uiautomator returns "null root node" unless a WSA window is actually on
      screen - injected input goes nowhere when mCurrentFocus is null, so the
      caller must have something visible first.
    #>
    param([Parameter(Mandatory)][string]$Adb, [string]$RemotePath = '/sdcard/wsa-autoinstall-ui.xml')

    $out = & $Adb -s $script:AdbTarget shell uiautomator dump $RemotePath 2>&1
    if ($out -match 'null root node') { return $null }
    (& $Adb -s $script:AdbTarget shell cat $RemotePath) -join ''
}

function Get-UiNode {
    # Returns nodes matching a raw attribute pattern, newest dump first.
    param([Parameter(Mandatory)][string]$Xml, [Parameter(Mandatory)][string]$Pattern)
    [regex]::Matches($Xml, '<node[^>]*/?>') |
        ForEach-Object { $_.Value } |
        Where-Object { $_ -match $Pattern }
}

function Get-UiCentre {
    # Bounds are real device pixels; tap the middle of the node.
    param([Parameter(Mandatory)][string]$Node)
    $b = [regex]::Match($Node, 'bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"')
    if (-not $b.Success) { return $null }
    [pscustomobject]@{
        X = [int]((([int]$b.Groups[1].Value) + ([int]$b.Groups[3].Value)) / 2)
        Y = [int]((([int]$b.Groups[2].Value) + ([int]$b.Groups[4].Value)) / 2)
    }
}

function Invoke-UiTap {
    param([Parameter(Mandatory)][string]$Adb, [Parameter(Mandatory)]$Point)
    & $Adb -s $script:AdbTarget shell input tap $Point.X $Point.Y | Out-Null
    Start-Sleep -Seconds 3
}

function Wait-WsaFocus {
    # Input injection needs a focused window; poll until one appears.
    param([Parameter(Mandatory)][string]$Adb, [string]$Match = '.', [int]$TimeoutSeconds = 45)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $focus = (& $Adb -s $script:AdbTarget shell dumpsys window 2>&1 |
                  Select-String 'mCurrentFocus') -join ''
        if ($focus -notmatch 'null' -and $focus -match $Match) { return $true }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    $false
}

# ------------------------------------------------------------------ root --

function Test-WsaRoot {
    # A granted policy returns uid=0; a denied one fails fast with
    # "Permission denied"; an undecided one blocks on the Magisk prompt.
    param([Parameter(Mandatory)][string]$Adb, [int]$TimeoutSeconds = 20)

    $job = Start-Job -ArgumentList $Adb, $script:AdbTarget -ScriptBlock {
        param($a, $t) & $a -s $t shell 'su -c id' 2>&1
    }
    if (Wait-Job $job -Timeout $TimeoutSeconds) {
        $r = (Receive-Job $job) -join ' '
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        if ($r -match 'uid=0')             { return 'granted' }
        if ($r -match 'Permission denied') { return 'denied'  }
        return 'unknown'
    }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    'pending'   # sitting on the superuser prompt
}

function Grant-WsaRoot {
    <#
      Magisk stores su policies in /data/adb/magisk.db inside the ext4
      userdata image, which Windows cannot read and `magisk --sqlite` cannot
      reach without root already - so the grant has to happen through the UI.
      Every coordinate here is discovered from a uiautomator dump rather than
      hardcoded, so it survives layout and resolution changes.
    #>
    param([Parameter(Mandatory)][string]$Adb)

    # su works against the native daemon long before Android is up, but the
    # Magisk UI this drives does not exist until the framework has started -
    # without this, Wait-WsaFocus just burns its timeout on an empty screen.
    if (-not (Wait-WsaFramework -Adb $Adb)) {
        Write-Warn 'Android is not up yet, so the Magisk UI cannot be driven'
        return $false
    }

    $state = Test-WsaRoot -Adb $Adb
    if ($state -eq 'granted') { Write-Ok 'Root already granted to Shell'; return $true }
    Write-Info "Current su state: $state"

    # Kick off an su request so a fresh install raises the prompt, then work
    # the UI while it waits.
    $pending = Start-Job -ArgumentList $Adb, $script:AdbTarget -ScriptBlock {
        param($a, $t) & $a -s $t shell 'su -c id' 2>&1
    }

    & $Adb -s $script:AdbTarget shell monkey -p com.topjohnwu.magisk `
        -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null

    if (-not (Wait-WsaFocus -Adb $Adb -Match 'magisk')) {
        Write-Warn 'The Magisk window never took focus; cannot inject input'
        Stop-Job $pending -EA SilentlyContinue; Remove-Job $pending -Force -EA SilentlyContinue
        return $false
    }

    $xml = Get-UiDump -Adb $Adb
    if (-not $xml) { Write-Warn 'No UI available to read'; return $false }

    # Case 1: the allow/deny prompt is up - tap its positive button.
    $grant = Get-UiNode -Xml $xml -Pattern 'text="(Grant|Allow)"' | Select-Object -First 1
    if ($grant) {
        Write-Info 'Superuser prompt is showing; granting'
        Invoke-UiTap -Adb $Adb -Point (Get-UiCentre -Node $grant)
    } else {
        # Case 2: no prompt (already answered once, or it timed out into a
        # deny) - go to Superuser and flip the Shell switch instead.
        $tab = Get-UiNode -Xml $xml -Pattern 'content-desc="Superuser"' | Select-Object -First 1
        if (-not $tab) { Write-Warn 'Could not find the Superuser tab'; return $false }
        Write-Info 'Opening the Superuser tab'
        Invoke-UiTap -Adb $Adb -Point (Get-UiCentre -Node $tab)

        $xml = Get-UiDump -Adb $Adb
        if ($xml -notmatch '(?i)shell') { Write-Warn 'No Shell entry listed under Superuser'; return $false }

        $sw = Get-UiNode -Xml $xml -Pattern 'class="android.widget.Switch"[^>]*checked="false"' |
              Select-Object -First 1
        if ($sw) {
            Write-Info 'Enabling su for Shell'
            Invoke-UiTap -Adb $Adb -Point (Get-UiCentre -Node $sw)
        } else {
            Write-Info 'Shell switch already enabled'
        }
    }

    Stop-Job $pending -EA SilentlyContinue; Remove-Job $pending -Force -EA SilentlyContinue

    if ((Test-WsaRoot -Adb $Adb) -eq 'granted') {
        Write-Ok 'Root granted to Shell (adb shell su now returns uid=0)'
        return $true
    }
    Write-Warn 'Root still not granted; open Magisk > Superuser and enable Shell by hand'
    $false
}

# ---------------------------------------------------------------- pacman --

function Install-WsaPacman {
    <#
      Registers the .apk/.xapk double-click handler. The installer is an
      unsigned Inno Setup build, so SmartScreen will flag it; the portable
      zip avoids that but registers no file associations.

      The installer build is bundled under vendor/, so the common path needs
      no network at all. Anything not bundled - the portable zip, by default -
      still resolves through the GitHub API.
    #>
    param([string]$Repo = 'alesimula/wsa_pacman', [switch]$Portable, [string]$PortableDir)

    if ($Portable -and -not $PortableDir) { throw 'PortableDir is required for a portable install.' }

    $wanted  = if ($Portable) { '*portable*.zip' } else { '*installer*.exe' }
    $package = Get-VendorFile "WSA-pacman-$wanted"
    $isTemp  = $false

    if ($package) {
        Write-Info "Using the bundled $(Split-Path $package -Leaf)"
    } else {
        $headers = @{ 'User-Agent' = 'wsa-autoinstall'; 'Accept' = 'application/vnd.github+json' }
        if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers

        $asset = $rel.assets | Where-Object { $_.name -like $wanted } | Select-Object -First 1
        if (-not $asset) { throw "No PacMan build matching $wanted in the latest release." }

        $package = Join-Path $env:TEMP $asset.name
        $isTemp  = $true
        Write-Info "Downloading WSA PacMan $($rel.tag_name)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $package -UseBasicParsing
    }

    if ($Portable) {
        Expand-Archive -Path $package -DestinationPath $PortableDir -Force
        # Only a temp download is ours to delete; a vendored copy stays put.
        if ($isTemp) { Remove-Item $package -Force -ErrorAction SilentlyContinue }
        Write-Ok "WSA PacMan (portable) at $PortableDir - no .apk association registered"
        return
    }

    Write-Info 'Installing silently'
    $p = Start-Process -FilePath $package -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    if ($isTemp) { Remove-Item $package -Force -ErrorAction SilentlyContinue }

    if ($p.ExitCode -ne 0) { throw "PacMan installer exited with $($p.ExitCode)." }
    Write-Ok 'WSA PacMan installed - .apk and .xapk now install on double-click'
}
