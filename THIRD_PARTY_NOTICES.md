# Third-party notices

Android Social Suite downloads or embeds third-party software and launches it as separate processes. Those components remain subject to their own terms.

## Android SDK, Android Emulator, Platform Tools, and system images

- Provider: Google LLC
- Website: https://developer.android.com/studio
- Terms: https://developer.android.com/studio/terms
- Distribution model: downloaded from official Google repositories after the user confirms the applicable terms

Android Social Suite does not grant rights to redistribute Google SDK components or Google Play system images.

## Xray-core

- Provider: Project X / XTLS
- Repository: https://github.com/XTLS/Xray-core
- License: Mozilla Public License 2.0
- Embedded version: v25.10.15 Windows x64, unmodified
- Distribution model: embedded in release executables and extracted as a separate executable at runtime
- Full license: https://www.mozilla.org/MPL/2.0/

## ZXing.Net

- Provider: Michael Jahn / ZXing.Net contributors
- Repository: https://github.com/micjahn/ZXing.Net
- License: Apache License 2.0
- Embedded version: 0.16.8.0, unmodified
- Purpose: in-memory decoding of proxy QR codes displayed on connected screens
- Privacy: screenshots are not saved to disk

## hev-socks5-tunnel / SocksTun

- Provider: hev and contributors
- Repositories: https://github.com/heiher/hev-socks5-tunnel and https://github.com/heiher/sockstun
- License: MIT
- Embedded native version: SocksTun 8.0 / hev-socks5-tunnel Android x86_64 library
- Purpose: per-device Android VpnService tunnel for TCP, UDP, IPv4, IPv6, and DNS traffic
- Distribution model: the native library is embedded in the managed Android VPN APK and its license is embedded in the Windows release executable

## PowerShell and .NET Framework

The launcher relies on Windows PowerShell and .NET Framework components supplied with supported Windows installations.
