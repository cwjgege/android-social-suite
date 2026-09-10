# Hysteria2 support / Hysteria2 支持

The Hysteria2-enabled EXE bundles an isolated Xray v26.3.27 core. Existing VLESS/VMess/Trojan/SS/HTTP/SOCKS nodes retain the original Xray core. Each Android phone keeps its own encrypted node binding and local proxy ports.

支持 hysteria2:// 与 hy2:// 粘贴或屏幕二维码导入；IPv4/域名/方括号 IPv6、认证信息、SNI、Salamander、端口范围与跳跃、证书 SHA-256 指纹及 ECH 配置。默认 UDP 443，测速以通过代理的 HTTPS 请求为准，不对 UDP 节点做 TCP 探测。

Limitations / 限制
- Gecko obfuscation, Hysteria Realms and unknown query parameters are rejected, not silently ignored.
- insecure=1 without pinSHA256 is rejected by this integration; use a valid trusted certificate or obtain the certificate fingerprint from your provider.
- 不支持仅跳过证书验证的自签名配置，需要提供 pinSHA256。不要自行删除混淆或证书参数来绕过导入错误。
- The host network must permit outbound UDP to the server. This feature does not guarantee better throughput or bypass host VPN routing.
- Stop a phone before replacing its node. When upgrading this component, stop existing Hysteria2 phones and close other manager windows first.

Build: run fetch-hysteria2-core.ps1, then build.ps1. The fetch script pins and checks the official archive SHA-256.

References: https://v2.hysteria.network/docs/developers/URI-Scheme/ and https://github.com/XTLS/Xray-core/tree/v26.3.27
