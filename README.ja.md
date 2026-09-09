# Android Social Suite

[English](README.en.md) | [简体中文](README.md) | 日本語 | [Español](README.es.md)

Android Social Suite は、Windows 向けのローカル Android マルチデバイス管理ツールです。公式 Android Emulator を利用し、デバイスごとの永続データ、個別プロキシ接続、メディア転送、APK インストールを提供します。Android Studio、Java、ADB、Xray、v2rayN の事前インストールは不要です。

> 本プロジェクトは初期段階です。インストール前に[互換性と制限](docs/COMPATIBILITY.md)を確認してください。SNS アカウントの安全性、実機としての認識、プラットフォーム規則の回避は保証しません。

## 主な機能

- Windows 上で Android 14 デバイスを作成、起動、停止、削除。
- デバイスごとに異なるプロキシ、Xray プロセス、Android VPN トンネルを割り当て。
- 内蔵の `VpnService + tun2socks` で TCP、UDP、IPv4、IPv6、DNS を経由。
- VLESS、VMess、Trojan、Shadowsocks、SOCKS5、HTTP/HTTPS を直接読み込み。
- Hysteria、WireGuard、高度な設定は Xray outbound JSON で読み込み。
- プロキシ情報を Windows DPAPI で暗号化。
- プロキシ出口 IP の確認。
- Pixel、Samsung 画面レイアウト、小型端末、タブレットのハードウェア設定。
- 写真と動画を `/sdcard/DCIM/AndroidSocialSuite/` にドラッグ＆ドロップ。
- 通常の単体 `.apk` を選択中の起動済みデバイスへドラッグしてインストール。
- アプリ、アカウント、メディアをデバイスごとに独立して保存。

## ダウンロードと初回起動

GitHub Releases から `AndroidSocialSuite.exe` をダウンロードしてください。Xray-core と管理対象 VPN APK は EXE に内蔵されています。初回起動時は Android コンポーネントを Google の公式配布元から取得するため、インターネット接続が必要です。

Intel VT-x または AMD-V/SVM と Windows Hypervisor Platform を有効にし、Windows を再起動してから使用してください。

## ビルド

64 ビット Windows PowerShell で次を実行します。

```powershell
.\build.ps1
```

成果物は `release\AndroidSocialSuite.exe` に生成されます。

## ライセンス

プロジェクトのソースコードは [Apache License 2.0](LICENSE) で公開します。第三者コンポーネントには、それぞれのライセンスが適用されます。
