# vendor/

Third-party files the installer would otherwise fetch at runtime. They are
committed so that a plain "Download ZIP" of this repository is enough to run
the installer on a machine with no internet access, or one where a DNS blip
would otherwise kill the run halfway through.

Each one is still downloaded automatically if the file is missing here, so
deleting anything in this folder only costs a download.

| File | Version | Source | Licence |
|------|---------|--------|---------|
| `7zr.exe` | 26.03 (2026-09-03) | <https://www.7-zip.org/a/7zr.exe> | 7-Zip licence (LGPL-2.1-or-later, redistribution permitted) |
| `platform-tools-latest-windows.zip` | 37.0.1 | <https://dl.google.com/android/repository/platform-tools-latest-windows.zip> | Android SDK Terms and Conditions |
| `WSA-pacman-v1.5.0-installer.exe` | 1.5.0 | <https://github.com/alesimula/wsa_pacman/releases/tag/v1.5.0> | GPL-3.0 |

SHA-256:

```
ad4c82fadcbdf93c03b4fc440f300509c7d60c5c2f4d183e35d9d70d6957037d  7zr.exe
45f4d63113e895ebde0c90f194099a4676b6ac653bd28d54314a9e022bbc1a99  platform-tools-latest-windows.zip
7abc29a8f808dc6db3aa692c6f917035036cb8d7fcceb81fe74f119e3add17a9  WSA-pacman-v1.5.0-installer.exe
```

## The Android platform-tools caveat

Google's Android SDK Terms and Conditions do not grant a redistribution right,
so this zip is bundled as a convenience and may have to come out if Google
objects. Delete it and the installer downloads `platform-tools-latest-windows.zip`
from `dl.google.com` exactly as it did before.

## The WSA image is not here

The WSABuilds `.7z` is 700 MB - 1 GB, well past GitHub's 100 MB per-file limit,
so it can never ship inside the source zip. To run with no downloads at all,
drop the `.7z` in this folder (or pass `-Archive <path>`) and the installer
uses it instead of contacting the GitHub API. See the README for details.

Files matching `WSA_*.7z` here are gitignored, so a local copy will not be
committed by accident.
