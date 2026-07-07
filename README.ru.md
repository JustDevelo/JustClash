<div align="center">

<img src="docs/icon.png" width="120" alt="JustClash" />

# JustClash

**Лёгкий VLESS / прокси-клиент для Windows и Android, оптимизированный под слабые устройства.**

[English](README.md) · [Русский](README.ru.md) · [中文](README.zh.md)

[![Release](https://img.shields.io/github/v/release/JustDevelo/JustClash?style=flat-square)](https://github.com/JustDevelo/JustClash/releases)
[![Downloads](https://img.shields.io/github/downloads/JustDevelo/JustClash/total?style=flat-square&logo=github)](https://github.com/JustDevelo/JustClash/releases)
[![Telegram](https://img.shields.io/badge/Telegram-Канал-blue?style=flat-square&logo=telegram)](https://t.me/justdevelo)

</div>

# О проекте

JustClash — простой, быстрый прокси-клиент для Windows и Android. Работает на ядре **Mihomo (Clash.Meta)**, которое встроено в приложение.

# Возможности

- **Защита всего трафика** — системный TUN на Windows, `VpnService` на Android
- **Импорт по ссылке-подписке в один клик** (VLESS и другие протоколы, Clash- и raw-конфиги) — вставь ссылку или отсканируй QR-код на Android
- **Автообновление подписок** — при запуске и в фоне
- **Выбор серверов и локаций**, группы прокси, замер задержки, флаги стран
- **Режимы «Правила» и «Прямое подключение»**
- **Встроенные гео-базы** с автообновлением
- **Темы**: светлая / тёмная / AMOLED-чёрная + выбор акцентного цвета
- **Язык**: русский, английский, китайский
- **Системный трей и автозапуск** (Windows), запуск в одном экземпляре
- **Низкое потребление ресурсов** — тихое ядро, спящий интерфейс; комфортно и на слабых ПК, и на телефона

## Какая у меня архитектура?
- **arm64-v8a** — почти все современные телефоны (примерно с 2018 года). Сомневаетесь — universal.
- **armeabi-v7a** — старые и очень бюджетные устройства.
- **x86_64** — эмуляторы Android на ПК, отдельные планшеты и Chromebook.

# Технологии

- Интерфейс: Flutter (Dart)
- Ядро: Mihomo (Clash.Meta, *позаимствовано от CMFA - https://github.com/MetaCubeX/ClashMetaForAndroid для Android*)

# Лицензия

См. файл LICENSE.
