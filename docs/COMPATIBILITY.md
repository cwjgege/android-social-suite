# Compatibility and limitations / 兼容性与限制

## Supported / 支持

| Area | Supported configuration |
| --- | --- |
| Operating system | 64-bit Windows 10 or Windows 11 |
| CPU | Intel x86-64 with VT-x/EPT or AMD x86-64 with AMD-V/RVI |
| Hypervisor | Windows Hypervisor Platform (WHPX), enabled before installation |
| Memory | 16 GB recommended for one or two running phones; 32 GB recommended for heavier profiles |
| Storage | SSD recommended; keep at least 24 GB free for installation and device data |
| Android | Android 14, API 34, x86_64 Google Play system image |
| Graphics | Host GPU acceleration when supported; software fallback may be slower |
| Proxy protocol | VLESS, VMess, Trojan, Shadowsocks, SOCKS5, HTTP/HTTPS; Xray outbound JSON for Hysteria and WireGuard |
| Proxy security | None, TLS, or REALITY, depending on the VLESS link |
| Media import | JPG, JPEG, PNG, WEBP, GIF, HEIC, HEIF, MP4, MOV, M4V, WEBM |
| Application install | Standard standalone `.apk` files |
| Device data | Persistent and isolated per AVD until that phone is deleted |

## Not supported / 不支持

| Area | Limitation |
| --- | --- |
| Operating system | 32-bit Windows, Windows 7/8, Windows on ARM, macOS, and Linux |
| CPU | ARM Windows PCs or processors without hardware virtualization |
| Hypervisor | Systems where VT-x/AMD-V is disabled or WHPX cannot be enabled |
| Offline setup | The public installer requires internet access on first run |
| APK bundles | `.xapk`, `.apks`, AAB, and split APK sets are not currently supported |
| Proxy hot swap | A phone must be stopped before its VLESS node is set, replaced, or cleared |
| UDP proxying | Android Emulator `-http-proxy` does not redirect UDP; QUIC/UDP traffic is not guaranteed to use VLESS |
| WireGuard concurrency | Xray warns that multiple WireGuard instances can contend for the same routing-table number; do not assume concurrent WireGuard devices are isolated without testing |
| Full device spoofing | Hardware profile selection changes display, density, memory, and CPU settings; it does not replace the Google system build fingerprint or guarantee physical-device identity |
| Platform guarantees | No guarantee of TikTok, Instagram, Google Play Integrity, account safety, or compliance decisions made by third-party platforms |
| Large fleets | The current Windows desktop edition is intended for small local fleets, not tens or hundreds of concurrent devices |
| Remote access | No browser control, multi-user access, RBAC, reservation, or cloud orchestration yet |

## Capacity guidance / 容量建议

| Host memory | Suggested simultaneous phones |
| --- | --- |
| 8 GB | Installation may work, but concurrent emulator use is not recommended |
| 16 GB | 1 to 2 standard phone profiles |
| 32 GB | 2 to 4 phones depending on CPU, GPU, applications, and media workload |
| 64 GB+ | More instances may be possible, but CPU/GPU and disk I/O remain limiting factors |

These are practical guidelines rather than guarantees. Android Emulator reserves guest memory at startup, and social video applications can substantially increase CPU, GPU, and memory use.

## Network behavior / 网络行为

- Each configured phone receives a dedicated local Xray HTTP inbound port.
- The emulator is launched with `-http-proxy` pointing to that dedicated port.
- HTTPS is tunneled without decryption.
- UDP is not redirected by Android Emulator's HTTP proxy.
- A distinct VLESS link does not guarantee a distinct exit IP; the provider must supply genuinely different exits.

## First-run requirements / 首次运行要求

- Internet access to Google Android repositories and GitHub/XTLS releases.
- Permission to write the selected installation directory.
- Acceptance of the Android SDK License Agreement.
- A Windows restart after enabling WHPX or BIOS virtualization when required.
