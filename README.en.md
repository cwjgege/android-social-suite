# Android Social Suite

English | [简体中文](README.md) | [日本語](README.ja.md) | [Español](README.es.md)

Android Social Suite is a local multi-device Android manager for Windows. It uses the official Android Emulator and provides persistent phones, per-device proxy routing, media import, and APK installation without requiring Android Studio, Java, ADB, Xray, or v2rayN to be preinstalled.

> This is an early-stage project. Read the [compatibility and limitations](docs/COMPATIBILITY.md) before installing. The project does not guarantee social-account safety, physical-device authenticity, or bypassing platform policies.

## Features

- Create, start, stop, and delete Android 14 devices on Windows.
- Assign a separate proxy and local Xray process to each phone.
- Import VLESS, VMess, Trojan, Shadowsocks, SOCKS5, and HTTP/HTTPS links.
- Import an Xray outbound JSON object for Hysteria, WireGuard, and advanced configurations.
- Encrypt saved proxy links and credentials with Windows DPAPI.
- Test the proxy exit IP.
- Select Pixel, Samsung-style screen layouts, compact phone, or tablet profiles.
- Drop photos and videos into `/sdcard/DCIM/AndroidSocialSuite/` and refresh the Android media library.
- Drop a standard standalone `.apk` onto the manager to install it on the selected running phone.
- Keep applications, accounts, and media isolated and persistent per device.
- Create clean devices from a protected background template.

## Download

Download `AndroidSocialSuite.exe` from GitHub Releases. The repository's [release/AndroidSocialSuite.exe](release/AndroidSocialSuite.exe) is also provided for the current preview.

Xray-core is embedded in the executable. The first run still requires internet access to download Android Emulator, Platform Tools, and the Android 14 Google Play image from Google. These components are reused on later launches.

## Quick start

1. Enable Intel VT-x or AMD-V/SVM in BIOS/UEFI.
2. Enable Windows Hypervisor Platform and restart Windows.
3. Run `AndroidSocialSuite.exe` and accept the Android SDK terms.
4. Create a phone and select a hardware profile.
5. While the phone is stopped, assign a proxy and test its exit IP.
6. Start the phone.
7. Select the running phone and drop photos, videos, or a standard APK onto the drop area.

## Build

Run the following command in 64-bit Windows PowerShell:

```powershell
.\build.ps1
```

The output is written to `release\AndroidSocialSuite.exe`.

## Screenshots

Follow the [screenshot checklist](docs/SCREENSHOTS.md) before publishing real screenshots. Blur account details, VLESS UUIDs, server addresses, and exit IPs.

## Third-party software

This repository does not include Android SDK or Google Play system images. Release executables embed an unmodified Xray-core binary with its MPL 2.0 notice. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

The project source is licensed under the [Apache License 2.0](LICENSE). Third-party components remain subject to their respective licenses.
