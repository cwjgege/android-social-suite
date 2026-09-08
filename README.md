# Android Social Suite

[English](README.en.md) | [日本語](README.ja.md) | [Español](README.es.md) | 简体中文

Android Social Suite 是面向 Windows 用户的本地 Android 多设备管理器。它基于官方 Android Emulator，提供设备创建、持久化存储、每设备独立代理、媒体导入和 APK 安装，无需预装 Android Studio、Java、ADB、Xray 或 v2rayN。

> 项目处于早期阶段。请先阅读[兼容性与限制](docs/COMPATIBILITY.md)。本项目不提供社交平台账号安全、设备真实性或平台规则规避保证。

## 功能

- 在 Windows 上创建、启动、关闭和删除 Android 14 设备。
- 为每台设备分配独立代理和本地 Xray 进程。
- 直接识别 VLESS、VMess、Trojan、Shadowsocks、SOCKS5 和 HTTP/HTTPS 分享链接。
- 通过 Xray outbound JSON 支持 Hysteria、WireGuard 和高级配置。
- 使用 Windows DPAPI 加密保存代理分享链接及凭据。
- 测试代理出口 IP。
- 新建设备时选择 Pixel、Samsung 屏幕布局、紧凑型手机或平板配置。
- 将图片和视频拖入 `/sdcard/DCIM/AndroidSocialSuite/` 并刷新 Android 媒体库。
- 将标准单体 `.apk` 拖入管理器并安装到选中的运行设备。
- 每台设备独立保存应用、账号和媒体数据。
- 使用受保护的后台模板创建干净设备。

## 下载

从 GitHub Releases 下载 `AndroidSocialSuite.exe`。仓库内的 [release/AndroidSocialSuite.exe](release/AndroidSocialSuite.exe) 也用于当前预览版本。

Xray 核心已嵌入 EXE。首次运行仍需联网从 Google 官方源下载 Android Emulator、Platform Tools 和 Android 14 Google Play 镜像，后续启动不需要重复下载。

## 快速开始

1. 在 BIOS/UEFI 中启用 Intel VT-x 或 AMD-V/SVM。
2. 在 Windows 功能中启用 Windows Hypervisor Platform，然后重启电脑。
3. 运行 `AndroidSocialSuite.exe` 并确认 Android SDK 许可。
4. 创建一台手机并选择硬件配置。
5. 在设备关闭时设置代理并测试出口 IP。
6. 启动设备。
7. 选中运行设备，将图片、视频或普通 APK 拖到窗口底部区域。

## 数据与删除

设备数据保存在安装目录的 `android-avd` 中。删除设备会将完整设备目录移入 Windows 回收站，其中包括应用、账号、缓存、图片和视频。清空回收站后才会永久删除。

VLESS 分享链接使用 Windows DPAPI 加密存放。设备运行时，Xray 需要在本机运行目录生成临时配置文件。不要公开提交安装目录、AVD 数据或代理配置。

## 构建

在 64 位 Windows PowerShell 中运行：

```powershell
.\build.ps1
```

生成文件位于 `release\AndroidSocialSuite.exe`。构建使用 Windows 自带的 .NET Framework C# 编译器。

## 截图

发布前请按照[截图清单](docs/SCREENSHOTS.md)添加真实截图，并隐藏账号、节点 UUID、服务器地址和出口 IP。

## 第三方组件

本仓库不包含 Android SDK 或 Google Play 系统镜像。发布版 EXE 嵌入未修改的 Xray 核心并附带 MPL 2.0 声明。详情参见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 开源许可

项目源码采用 [Apache License 2.0](LICENSE)。第三方组件继续受各自许可证约束。
