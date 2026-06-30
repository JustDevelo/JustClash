import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  ProxyElement
//  Модель одного прокси-узла (сервера) из подписки.
//
//  Объединяет параметры всех поддерживаемых протоколов (VLESS / VMess / Trojan /
//  Shadowsocks / Hysteria2 / TUIC / WireGuard / SOCKS5 / HTTP). Для конкретного
//  протокола часть полей остаётся со значениями по умолчанию.
//
//  Кроме статичных параметров хранит «живой» пинг через [pingNotifier],
//  за которым следит UI списка прокси (обновляется без перестройки списка).
// ═══════════════════════════════════════════════════════════════════════════

/// Модель прокси-узла: транспортные/TLS-параметры + реактивный пинг для UI.
class ProxyElement {
  // ───────────────────────── Базовые поля узла ─────────────────────────

  /// Отображаемое имя узла (как в подписке).
  final String name;

  /// UUID узла (используется протоколами VLESS/VMess).
  final String uuid;

  /// Адрес сервера (домен или IP).
  final String server;

  /// Порт сервера.
  final int port;

  /// alterId (актуально для VMess; по умолчанию 0).
  final int alterId;

  // ──────────────── Транспорт и TLS-параметры ──────────────────

  /// Тип транспорта: tcp/ws/grpc и т.п.
  final String network;

  /// Тип безопасности: none/tls/reality.
  final String security;

  /// SNI (имя сервера для TLS).
  final String sni;

  /// Path для ws/grpc-транспорта.
  final String path;

  /// Host-заголовок (ws) / authority (grpc).
  final String host;

  /// Публичный ключ (REALITY).
  final String publicKey;

  /// short-id (REALITY).
  final String shortId;

  /// Отпечаток TLS-клиента (uTLS), по умолчанию chrome.
  final String fingerprint;

  // ──────────────── Шифрование и тип протокола ────────────────

  /// Шифр (Shadowsocks/VMess), по умолчанию auto.
  final String cipher;

  /// flow (VLESS, например xtls-rprx-vision).
  final String flow;

  /// Тип протокола узла: vless/vmess/trojan/ss/hysteria2/tuic/...
  final String protocolType;

  // ────────── Параметры Hysteria2 / обфускации ────────────

  /// Тип обфускации (obfs).
  final String obfs;

  /// Пароль обфускации.
  final String obfsPassword;

  /// Диапазон портов (для протоколов с port hopping, напр. Hysteria2).
  final String ports;

  // ───────────────────── Прочие флаги ───────────────────────

  /// Разрешить небезопасный TLS (в конфиге это skip-cert-verify).
  final bool allowInsecure;

  // ───────────── Реактивный пинг для UI ───────────────────

  /// Текущее значение пинга узла; UI подписан и обновляется автоматически.
  /// Начальное значение '---' — пинг ещё не измерялся.
  final ValueNotifier<String> pingNotifier;

  /// Признак того, что объект уже освобождён (см. [dispose]).
  bool _isDisposed = false;

  /// Публичный доступ к статусу «освобождён».
  bool get isDisposed => _isDisposed;

  ProxyElement({
    required this.name,
    required this.uuid,
    required this.server,
    required this.port,
    this.alterId = 0,
    this.network = 'tcp',
    this.security = 'none',
    this.sni = '',
    this.path = '',
    this.host = '',
    this.publicKey = '',
    this.shortId = '',
    this.fingerprint = 'chrome',
    this.cipher = 'auto',
    this.flow = '',
    this.protocolType = 'vless',
    this.obfs = '',
    this.obfsPassword = '',
    this.ports = '',
    this.allowInsecure = false,
  }) : pingNotifier = ValueNotifier<String>('---');

  // ───────────────────────────── Методы ─────────────────────────────

  /// Обновить значение пинга (игнорируется, если объект уже освобождён).
  void updatePing(String value) {
    if (_isDisposed) return;
    pingNotifier.value = value;
  }

  /// Освободить ресурсы (ValueNotifier). Повторный вызов безопасен.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    pingNotifier.dispose();
  }
}
