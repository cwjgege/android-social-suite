# Embedded Xray build input

Run `fetch-xray.ps1` to place the pinned official `xray.exe` and MPL 2.0 license in this directory before building.

The generated Android Social Suite executable embeds the unmodified Xray binary as a separate executable resource. At runtime it is extracted to the suite installation directory and launched as a separate process.

Upstream: https://github.com/XTLS/Xray-core

