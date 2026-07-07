<div align="center">

<img src="docs/icon.png" width="120" alt="JustClash" />

# JustClash

**轻量级 Windows 与 Android VLESS / 代理客户端，专为低配置设备优化。**

[English](README.md) · [Русский](README.ru.md) · [中文](README.zh.md)

[![Release](https://img.shields.io/github/v/release/JustDevelo/JustClash?style=flat-square)](https://github.com/JustDevelo/JustClash/releases)
[![Downloads](https://img.shields.io/github/downloads/JustDevelo/JustClash/total?style=flat-square&logo=github)](https://github.com/JustDevelo/JustClash/releases)
[![Telegram](https://img.shields.io/badge/Telegram-Канал-blue?style=flat-square&logo=telegram)](https://t.me/justdevelo)

</div>

# 简介

JustClash 是一款简洁、快速的 Windows 与 Android 代理客户端。基于 **Mihomo (Clash.Meta)** 内核，内核已内置于应用中。

# 功能

- **全局流量保护** — Windows 使用系统 TUN 模式，Android 使用 `VpnService`
- **一键导入订阅**（支持 VLESS 等协议、Clash 与原始配置）— 粘贴链接，或在 Android 上扫描二维码
- **自动更新订阅** — 启动时与后台自动更新
- **服务器 / 节点选择**、代理分组、延迟测试、国家旗帜
- **规则模式与直连模式**
- **内置 Geo 数据库**，自动更新
- **主题**：浅色 / 深色 / 纯黑（AMOLED）+ 强调色
- **语言**：俄语、英语、中文
- **系统托盘与开机自启**（Windows）、单实例运行
- **低资源占用** — 内核安静、界面空闲；低配电脑和手机都能流畅运行

## 我该选哪个架构？

- **arm64-v8a** — 几乎所有现代手机（大约 2018 年之后的机型）。不确定就选 universal。
- **armeabi-v7a** — 老旧或非常低端的设备。
- **x86_64** — PC 上的 Android 模拟器、部分平板电脑和 Chromebook。

# 技术栈

- 界面：Flutter (Dart)
- 内核：Mihomo (Clash.Meta，*Android 版内核借鉴自 CMFA — https://github.com/MetaCubeX/ClashMetaForAndroid*)

# 许可证

请见 LICENSE 文件。
