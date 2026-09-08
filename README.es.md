# Android Social Suite

[English](README.en.md) | [简体中文](README.md) | [日本語](README.ja.md) | Español

Android Social Suite es un administrador local de múltiples dispositivos Android para Windows. Utiliza el Android Emulator oficial y ofrece datos persistentes, proxy independiente por dispositivo, importación de contenido multimedia e instalación de APK sin requerir Android Studio, Java, ADB, Xray ni v2rayN preinstalados.

> El proyecto se encuentra en una fase inicial. Consulta la [compatibilidad y las limitaciones](docs/COMPATIBILITY.md) antes de instalarlo. No garantiza la seguridad de cuentas sociales, la identidad de un dispositivo físico ni la evasión de políticas de plataformas.

## Funciones

- Crear, iniciar, detener y eliminar dispositivos Android 14 en Windows.
- Asignar un proxy y un proceso Xray independiente a cada dispositivo.
- Importar enlaces VLESS, VMess, Trojan, Shadowsocks, SOCKS5 y HTTP/HTTPS.
- Importar objetos JSON outbound de Xray para Hysteria, WireGuard y configuraciones avanzadas.
- Cifrar enlaces y credenciales mediante Windows DPAPI.
- Comprobar la IP de salida del proxy.
- Elegir perfiles Pixel, diseños de pantalla Samsung, teléfono compacto o tableta.
- Arrastrar fotos y vídeos a `/sdcard/DCIM/AndroidSocialSuite/` y actualizar la biblioteca multimedia.
- Arrastrar un `.apk` estándar para instalarlo en el dispositivo seleccionado y encendido.
- Mantener aplicaciones, cuentas y archivos separados y persistentes por dispositivo.

## Descarga y primer inicio

Descarga `AndroidSocialSuite.exe` desde GitHub Releases. Xray-core está integrado en el EXE. El primer inicio requiere Internet para descargar Android Emulator, Platform Tools y la imagen Android 14 con Google Play desde Google.

Se requiere Windows de 64 bits, Intel VT-x o AMD-V/SVM y Windows Hypervisor Platform.

## Compilación

Ejecuta lo siguiente en Windows PowerShell de 64 bits:

```powershell
.\build.ps1
```

El resultado se guarda en `release\AndroidSocialSuite.exe`.

## Licencia

El código fuente del proyecto utiliza la [Apache License 2.0](LICENSE). Los componentes de terceros mantienen sus propias licencias.
