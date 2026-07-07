<div align="center">

<img src="docs/icon.png" width="120" alt="JustClash logo" />

# JustClash

**Lightweight VPN client for Windows & Android, optimized for low-end devices.**

[English](README.md) · [Русский](README.ru.md) · [中文](README.zh.md)

[![Release](https://img.shields.io/github/v/release/JustDevelo/JustClash?style=flat-square)](https://github.com/JustDevelo/JustClash/releases)
[![Downloads](https://img.shields.io/github/downloads/JustDevelo/JustClash/total?style=flat-square&logo=github)](https://github.com/JustDevelo/JustClash/releases)
[![Telegram](https://img.shields.io/badge/Telegram-Канал-blue?style=flat-square&logo=telegram)](https://t.me/justdevelo)

</div>

# Overview

JustClash is a simple, fast VPN client for Windows and Android. It runs on the **Mihomo (Clash.Meta)** core, bundled inside the app.

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

## Which architecture do I need?

- **arm64-v8a** — almost all modern phones. Not sure — *universal*
- **armeabi-v7a** — old and very budget devices.
- **x86_64** — Android emulators on PC, some tablets, and Chromebooks.

## Built with

- UI: Flutter (Dart)
- Core: Mihomo (Clash.Meta, *the Android core is borrowed from CMFA — https://github.com/MetaCubeX/ClashMetaForAndroid*)

# License

See LICENSE.
