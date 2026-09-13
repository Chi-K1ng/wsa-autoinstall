# wsa-autoinstall

One-click install for **Windows Subsystem for Android** on Windows 10 and 11, using the
prebuilt images from [MustardChef/WSABuilds](https://github.com/MustardChef/WSABuilds).

Microsoft ended WSA support in March 2025 and pulled it from the Store, so the only
remaining route is sideloading a prebuilt image. WSABuilds does the hard part — it
ships excellent images with Play Store and Magisk baked in, and a working `Install.ps1`.
What it doesn't do is get you from *"which of these seven 700 MB files do I want"* to a
booted, rooted, adb-reachable Android in one step. That's what this does.

```
Install-WSA.bat        <- double-click this
```

---

## What it does

1. Checks the Windows build, architecture and free disk space.
2. Enables `VirtualMachinePlatform` and the sideloading unlock, and tells you if a
   reboot is needed.
3. Asks the GitHub API for the newest WSABuilds release matching your OS and
   architecture — so it never goes stale as upstream publishes new builds.
4. Picks the right variant from the release's cryptic filenames based on whether you
   want root, the Play Store and the Amazon Appstore.
5. Downloads it, resumably. Ctrl+C is safe; rerunning continues where it stopped.
6. Extracts the `.7z` using Windows' own `tar.exe`.
7. Runs the build's own `Install.ps1` to register the package.
8. **Turns on Developer mode automatically** so adb works without touching the UI.
9. Boots the VM, installs `adb`, adds it to PATH and connects.
10. **Grants root to the adb shell automatically.**
11. Installs [WSA PacMan](https://github.com/alesimula/wsa_pacman) so `.apk` and
    `.xapk` files install on double-click.

## What you see while it runs

It runs in a console window and reports the whole way through — every step is
numbered and timed, and nothing goes quiet for more than a second or two:

```
  [6/13] Downloading
    Size 740 MB
    To   D:\WSA\WSA_2407.40000.4.0_x64_Release-Nightly-with-magisk...7z
    Ctrl+C is safe here - rerunning resumes where it stopped

  % Total    % Received  Average Speed   Time    Time     Time  Current
                          Dload  Upload  Total   Spent    Left  Speed
 47  740M   47  350M    0     0  38.4M      0  0:00:19  0:00:09  0:00:10 39.1M

    [ok] Downloaded 740 MB in 0m 19s at 38.4 MB/s
    done in 0m 21s

  [7/13] Extracting
    Extracting with bsdtar - 1.87 GB written, 0m 14s elapsed
```

The download meter is `curl`'s own. Extraction and the first boot have no
progress to report of their own, so those lines are measured live — bytes
written into the install folder, and a countdown while the VM comes up. The
window stays open at the end, and every run is written to
`%TEMP%\wsa-autoinstall-<timestamp>.log`.

## Requirements

- Windows 10 build 19045+ or Windows 11 build 22000+, x64 or arm64
- Virtualisation enabled in the BIOS (SVM on AMD, VT-x on Intel)
- ~8 GB free disk space
- Administrator rights — the `.bat` requests them itself

## Unattended use

Every prompt is also a parameter:

```powershell
.\scripts\Install-WSA.ps1 -InstallDir D:\WSA -Unattended
.\scripts\Install-WSA.ps1 -InstallDir D:\WSA -Root No -Amazon Yes -Pacman No -Unattended
.\scripts\Install-WSA.ps1 -PacmanPortable -KeepArchive
```

| Parameter | Default | Meaning |
|---|---|---|
| `-InstallDir` | `C:\WSA` | Where WSA lives permanently |
| `-Root` | `Yes` | Pick a Magisk build and grant su to the shell |
| `-GApps` | `Yes` | Google Play Store |
| `-Amazon` | `No` | Amazon Appstore |
| `-Adb` | `Yes` | Install platform-tools and add to PATH |
| `-Pacman` | `Yes` | Register the `.apk` double-click handler |
| `-DevMode` | `Yes` | Turn on WSA Developer mode |
| `-PacmanPortable` | off | Use PacMan's portable zip (no SmartScreen prompt, but no file association either) |
| `-KeepArchive` | off | Keep the downloaded `.7z` |
| `-Unattended` | off | Never prompt; take defaults |

## How the interesting bits work

### Developer mode, without touching the UI

WSA stores its Developer mode toggle as a UWP **LocalSettings** value named
`DeveloperModeEnabled`. `ApplicationDataManager.CreateForPackageFamily` reaches another
package's settings store from a full-trust process, so this needs no admin rights, no
UI automation and no shutdown:

```powershell
$ls = [Windows.Management.Core.ApplicationDataManager]::CreateForPackageFamily($pfn).LocalSettings
[System.Collections.Generic.IDictionary[string,object]].GetMethod('set_Item').
    Invoke($ls.Values, [object[]]@('DeveloperModeEnabled', [object]$true))
```

The reflected `set_Item` is needed because PowerShell can't do an indexed *set* on a
WinRT property set — `$ls.Values['x'] = $y` throws `CannotIndex`.

### Extracting `.7z` with no dependencies

`C:\Windows\System32\tar.exe` is bsdtar, and current Windows builds carry libarchive
3.4+, which reads 7-Zip archives. No 7-Zip install needed. Older hosts fall back to
downloading `7zr.exe`.

### Granting root

Magisk keeps su policies in `/data/adb/magisk.db`, inside the ext4 userdata image.
Windows can't read ext4, and `magisk --sqlite` needs root already — so the grant has
to go through the UI. The installer triggers an `su` request, then drives Magisk with
`uiautomator`, **discovering** the button and switch positions from the UI dump rather
than hardcoding coordinates, so it survives layout and resolution changes.

One real constraint: **injected input only lands when a WSA window is actually on
screen.** With everything hidden, `dumpsys window` reports `mCurrentFocus=null`,
`uiautomator dump` returns `null root node`, and taps go nowhere. The installer waits
for focus and warns you to keep the window visible. If the grant doesn't take, open
Magisk → Superuser and enable Shell by hand — everything else is already done.

## Gotchas worth knowing

- **Don't move the install folder.** WSA is registered in development mode and runs
  *from* that directory. Moving it breaks the install; re-register with
  `Add-AppxPackage -Register` after any move.
- **`!App`, not `!SettingsApp`.** Only the `!App` launch alias boots the VM.
  `!SettingsApp` opens Settings and leaves adb unreachable.
- **Target adb explicitly.** If you have other devices attached, a bare `adb install`
  is ambiguous:
  ```
  adb -s 127.0.0.1:58526 install yourapp.apk
  ```
- **`adb root` won't work** — it's refused on production builds. Root is via Magisk's
  `su`, which is what this sets up.
- **arm64-only APKs work.** The images ship libhoudini, so `ro.product.cpu.abilist`
  includes `arm64-v8a`.
- **Play Store sign-in rejected as uncertified?** Register the GSF ID at
  [google.com/android/uncertified](https://www.google.com/android/uncertified).
- WSA PacMan has been dormant since July 2023 and its installer is unsigned, so
  SmartScreen will warn. Use `-PacmanPortable` or `-Pacman No` to skip it.

## Credit and licence

All the actual WSA images are built and maintained by
[MustardChef/WSABuilds](https://github.com/MustardChef/WSABuilds), which builds on
[LSPosed/MagiskOnWSALocal](https://github.com/LSPosed/MagiskOnWSALocal). This project
only automates fetching and setting them up — it redistributes nothing.

Licensed under **AGPL-3.0-or-later**, matching upstream. See [LICENSE](LICENSE).

## Reporting a problem

Every run writes a transcript to `%TEMP%\wsa-autoinstall-<timestamp>.log`. On a failure
the script prints the exact path. Attach the newest one to an issue — it captures the
release and variant chosen, every step taken, and the full error with its line number.
