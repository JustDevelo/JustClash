<div align="center">

<img src="docs/icon.png" width="120" alt="JustClash logo" />

# JustClash

**Lightweight VLESS / proxy client for Windows & Android, optimized for low-end devices.**

English · Русский · 中文

![Release](https://github.com/JustDevelo/JustClash/releases)
![Downloads](https://github.com/JustDevelo/JustClash/releases)
![Telegram](https://t.me/justdevelo)

</div>

# Overview

JustClash is a simple, fast proxy client for Windows and Android. It runs on the **Mihomo (Clash.Meta)** core, bundled inside the app.

# Screenshots

<p align="center">
  <img src="docs/photo_2026-06-30_19-54-37.jpg" width="32%" />
  <img src="docs/photo_2026-06-30_19-54-52.jpg" width="32%" />
  <img src="docs/photo_2026-06-30_19-54-56.jpg" width="32%" />
  <img src="docs/photo_2026-06-30_19-54-59.jpg" width="32%" />
</p>

# Features

- **System-wide traffic protection** — TUN mode on Windows, `VpnService` on Android
- **One-click subscription import** (VLESS and other protocols, Clash and raw configs) — paste a link, or scan a QR code on Android
- **Automatic subscription updates** — on launch and in the background
- **Server / location selector**, proxy groups, latency test, country flags
- **Rule mode and Direct mode**
- **Bundled geo databases** with auto-update
- **Themes**: light / dark / pure black (AMOLED) + accent color
- **Languages**: Russian, English, Chinese
- **System tray & autostart** (Windows), single instance
- **Low resource usage** — quiet core, idle UI; comfortable on low-end PCs and phones

# Download

<div align="center">

<img src="https://raw.githubusercontent.com/Kunzisoft/Github-badge/main/get-it-on-github.png" alt="Get it on GitHub" height="70">

</div>

Pick the build for your device. Android APKs are split per architecture — if you're not sure, grab **universal** (works on any device, just a bit larger).

| OS | Downloads |
| :---: | :--- |
| **Android** | ![universal](https://github.com/JustDevelo/JustClash/releases/latest/download/JustClash-android-universal.apk) ![arm64-v8a](https://github.com/JustDevelo/JustClash/releases/latest/download/JustClash-android-arm64-v8a.apk) ![armeabi-v7a](https://github.com/JustDevelo/JustClash/releases/latest/download/JustClash-android-armeabi-v7a.apk) ![x86_64](https://github.com/JustDevelo/JustClash/releases/latest/download/JustClash-android-x86_64.apk) |
| **Windows** | ![Setup amd64](https://github.com/JustDevelo/JustClash/releases/latest/download/JustClash-windows-amd64-setup.exe) ![Portable amd64](https://github.com/JustDevelo/JustClash/releases/latest/download/JustClash-windows-amd64.zip) |

> **Android** — on first connect allow the VPN permission (and "install from unknown sources" if prompted). Also, if your device has battery activity control, it's best to set it to *Unrestricted*.
> **Windows** — *Setup* installs the app; *Portable* runs from any folder without installation.

## Which architecture do I need?

- **arm64-v8a** — almost all modern phones (roughly since 2018). Not sure — go with universal.
- **armeabi-v7a** — old and very budget devices.
- **x86_64** — Android emulators on PC, some tablets, and Chromebooks.

# Built with

- UI: Flutter (Dart)
- Core: Mihomo (Clash.Meta, *the Android core is borrowed from CMFA — https://github.com/MetaCubeX/ClashMetaForAndroid*)

# License

See LICENSE.
