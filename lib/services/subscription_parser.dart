// ═══════════════════════════════════════════════════════════════════════════
// SubscriptionParser — загрузка подписки и её преобразование в конфиг Clash.
//
// Назначение файла:
//   • Скачать содержимое подписки по URL (с HWID-заголовками и лимитом 5 МБ).
//   • Определить формат: готовый Clash YAML или «сырой» список ссылок
//     (vless/vmess/ss/trojan/hysteria2/tuic/wireguard/socks/http), в том числе
//     завёрнутый в Base64.
//   • Привести профиль к единому YAML с принудительными секциями JustClash
//     (external-controller, secret, mixed-port, tun, dns и прочее).
//   • Атомарно сохранить .yaml-конфиг и .json-метаданные профиля (.tmp/.bak).
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../exceptions/subscription_exception.dart';
import '../models/proxy_element.dart';
import 'settings_service.dart';
import 'device_service.dart';

/// Парсер подписок: качает, нормализует и сохраняет конфигурацию профиля.
class SubscriptionParser {
  // ─── Вспомогательные функции декодирования и санитизации ───

  /// Экранирует строку для безопасной вставки в YAML в двойных кавычках:
  /// удаляет управляющие символы, экранирует обратный слэш и кавычку.
  String _sanitizeYamlString(String input) {
    return input
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"');
  }

  /// Декодирует Base64 (в том числе URL-safe вариант), добивая недостающие
  /// символы выравнивания. Бросает SubscriptionException при ошибке.
  String _safeBase64Decode(String input) {
    try {
      String normalized = input
          .replaceAll(RegExp(r'[\s\n\r]'), '')
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } catch (e) {
      throw SubscriptionException('Ошибка декодирования Base64: $e');
    }
  }

  /// Безопасно декодирует percent-encoding; при ошибке возвращает исходную
  /// строку, заменив «+» на пробел.
  String _safeUrlDecode(String? value) {
    if (value == null || value.isEmpty) return '';
    try {
      return Uri.decodeComponent(value.replaceAll('+', ' '));
    } catch (_) {
      return value.replaceAll('+', ' ');
    }
  }

  /// Трактует значение как «разрешить небезопасный TLS» для 1/true/yes.
  bool _isInsecureValue(String? v) {
    if (v == null) return false;
    final String t = v.trim().toLowerCase();
    return t == '1' || t == 'true' || t == 'yes';
  }

  /// Проверяет флаги allowInsecure/insecure/allow_insecure в query-параметрах.
  bool _parseInsecureFlag(Map<String, String> q) {
    return _isInsecureValue(q['allowInsecure']) ||
        _isInsecureValue(q['insecure']) ||
        _isInsecureValue(q['allow_insecure']);
  }

  /// Разбирает заголовок subscription-userinfo: upload/download/total/expire.
  Map<String, dynamic> _parseUserInfo(String? header) {
    final Map<String, dynamic> info = {
      'upload': 0,
      'download': 0,
      'total': 0,
      'expire': 0,
    };
    if (header == null || header.isEmpty) return info;

    final List<String> parts = header.split(';');
    for (final part in parts) {
      final List<String> kv = part.split('=');
      if (kv.length == 2) {
        final String key = kv[0].trim().toLowerCase();
        final String value = kv[1].trim();
        if (key == 'upload' || key == 'download' || key == 'total') {
          info[key] = int.tryParse(value) ?? 0;
        } else if (key == 'expire') {
          info[key] = int.tryParse(value) ?? 0;
        }
      }
    }
    return info;
  }

  // ─── Основной сценарий: скачивание и сохранение подписки ───

  /// Скачивает подписку по [url], формирует YAML-конфиг и атомарно сохраняет
  /// его вместе с JSON-метаданными под именем [profileName]. Бросает
  /// SubscriptionException с локализованным текстом при любой ошибке.
  Future<void> fetchAndSaveSubscription(String url, String profileName) async {
    final s = SettingsService();
    final client = http.Client();
    final List<int> bytes = [];
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'clash-verge/1.3.8';

      final hwidHeaders = await DeviceService().getSubscriptionHeaders();
      request.headers.addAll(hwidHeaders);

      final response =
          await client.send(request).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        throw SubscriptionException(
          s.tr(
            'Ошибка сети: код ${response.statusCode}',
            'Network error: status code ${response.statusCode}',
            '网络错误：状态码 ${response.statusCode}',
          ),
        );
      }

      int totalBytes = 0;
      await for (final chunk in response.stream) {
        totalBytes += chunk.length;
        if (totalBytes > 5 * 1024 * 1024) {
          throw SubscriptionException(
            s.tr(
              'Файл слишком большой (максимум 5 МБ)',
              'File too large (max 5MB)',
              '文件过大（最大 5MB）',
            ),
          );
        }
        bytes.addAll(chunk);
      }

      final String body = utf8.decode(bytes, allowMalformed: true).trim();
      String cleanContent = body;
      final String lowerBody = body.toLowerCase();

      final hasKeywords = lowerBody.contains('proxies:') ||
          lowerBody.contains('proxy:') ||
          lowerBody.contains('vless://') ||
          lowerBody.contains('vmess://') ||
          lowerBody.contains('ss://') ||
          lowerBody.contains('trojan://') ||
          lowerBody.contains('hysteria2://') ||
          lowerBody.contains('hy2://') ||
          lowerBody.contains('tuic://') ||
          lowerBody.contains('wg://') ||
          lowerBody.contains('wireguard://') ||
          lowerBody.contains('socks://') ||
          lowerBody.contains('socks5://') ||
          lowerBody.contains('http://');

      if (!hasKeywords) {
        try {
          cleanContent = _safeBase64Decode(body);
        } catch (_) {
          throw SubscriptionException(
            s.tr(
              'Неизвестный формат ссылки. Убедитесь, что ссылка верна и не заблокирована провайдером.',
              'Unknown link format. Make sure the link is valid and not blocked.',
              '未知的链接格式。请确认链接有效且未被屏蔽。',
            ),
          );
        }
      }

      String yamlConfig;
      bool isClashConfig = false;
      int rawSkippedNodes = 0;
      int rawTotalNodes = 0;

      if (cleanContent.contains('proxies:')) {
        try {
          final dynamic parsedYaml = loadYaml(cleanContent);
          if (parsedYaml is! YamlMap) {
            throw Exception('YAML document is not a Map');
          }
          yamlConfig = _patchProviderClashConfig(cleanContent, parsedYaml);
          isClashConfig = true;
        } catch (e) {
          throw SubscriptionException(
            s.tr(
              'Ошибка синтаксического разбора YAML-файла провайдера: $e',
              'Error parsing provider\'s YAML file: $e',
              '解析提供商的 YAML 文件时出错：$e',
            ),
          );
        }
      } else {
        final List<ProxyElement> proxies = [];
        int skippedCount = 0;
        final lines = cleanContent.split('\n');

        for (final line in lines) {
          final trimmedLine = line.trim();
          if (trimmedLine.isEmpty) continue;
          try {
            proxies.add(_parseProxyUri(trimmedLine));
          } catch (e) {
            skippedCount++;
            debugPrint('Пропущен невалидный узел: $trimmedLine. Ошибка: $e');
          }
        }

        rawSkippedNodes = skippedCount;
        rawTotalNodes = proxies.length + skippedCount;

        if (proxies.isEmpty) {
          throw SubscriptionException(
            s.tr(
              'В подписке не найдено ни одного рабочего узла. Пропущено: $skippedCount.',
              'No valid nodes found in subscription. Skipped: $skippedCount.',
              '订阅中未找到任何有效节点。已跳过：$skippedCount。',
            ),
          );
        }

        try {
          yamlConfig = _buildClashYaml(proxies);
        } finally {
          for (final p in proxies) {
            p.dispose();
          }
        }
      }

      final Directory docDir = await getApplicationDocumentsDirectory();
      final String profilesPath = p.join(docDir.path, 'JustClash', 'profiles');
      final Directory profilesDir = Directory(profilesPath);

      if (!await profilesDir.exists()) {
        await profilesDir.create(recursive: true);
      }

      final String sanitizedName = profileName.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );

      final File configFile = File(p.join(profilesPath, '$sanitizedName.yaml'));
      final File tempConfigFile = File('${configFile.path}.tmp');
      await tempConfigFile.writeAsString(yamlConfig, flush: true);

      final File backupFile = File('${configFile.path}.bak');
      if (await configFile.exists()) {
        try {
          if (await backupFile.exists()) await backupFile.delete();
          await configFile.rename(backupFile.path);
        } catch (e) {
          try {
            await configFile.writeAsString(yamlConfig, flush: true);
            await tempConfigFile.delete();
          } catch (writeErr) {
            throw SubscriptionException(
              s.tr(
                'Файл конфигурации заблокирован другим процессом: $writeErr',
                'Config file is locked by another process: $writeErr',
                '配置文件被另一个进程锁定：$writeErr',
              ),
            );
          }
        }
      }

      if (await tempConfigFile.exists()) {
        try {
          await tempConfigFile.rename(configFile.path);
          if (await backupFile.exists()) await backupFile.delete();
        } catch (e) {
          try {
            await configFile.writeAsString(yamlConfig, flush: true);
            await tempConfigFile.delete();
          } catch (_) {
            if (await backupFile.exists()) {
              await backupFile.rename(configFile.path);
            }
            throw SubscriptionException(
              s.tr(
                'Не удалось применить конфигурационный файл: $e',
                'Failed to apply config file: $e',
                '无法应用配置文件：$e',
              ),
            );
          }
        }
      }

      final File metaFile = File(p.join(profilesPath, '$sanitizedName.json'));
      final File tempMetaFile = File('${metaFile.path}.tmp');
      final File backupMetaFile = File('${metaFile.path}.bak');

      String? userInfoHeader;
      response.headers.forEach((key, val) {
        if (key.toLowerCase() == 'subscription-userinfo') {
          userInfoHeader = val;
        }
      });
      final Map<String, dynamic> userInfo = _parseUserInfo(userInfoHeader);
      userInfo['last_update'] = DateTime.now().millisecondsSinceEpoch;
      userInfo['source_type'] = isClashConfig ? 'clash' : 'raw';
      userInfo['skipped_nodes'] = rawSkippedNodes;
      userInfo['total_nodes'] = rawTotalNodes;

      // Всегда сохраняем URL подписки, использованный для этой загрузки, чтобы
      // фоновое автообновление гарантированно нашло его позже — даже если
      // прежний meta-файл отсутствовал или был повреждён. К старому meta
      // обращаемся только если URL для этого вызова не передан.
      if (url.isNotEmpty) {
        userInfo['subscription_url'] = url;
      } else if (await metaFile.exists()) {
        try {
          final oldMeta = jsonDecode(await metaFile.readAsString());
          if (oldMeta is Map && oldMeta['subscription_url'] != null) {
            userInfo['subscription_url'] = oldMeta['subscription_url'];
          }
        } catch (_) {}
      }

      await tempMetaFile.writeAsString(jsonEncode(userInfo), flush: true);

      if (await metaFile.exists()) {
        try {
          if (await backupMetaFile.exists()) await backupMetaFile.delete();
          await metaFile.rename(backupMetaFile.path);
        } catch (_) {}
      }

      try {
        await tempMetaFile.rename(metaFile.path);
        if (await backupMetaFile.exists()) await backupMetaFile.delete();
      } catch (e) {
        if (await backupMetaFile.exists()) {
          try {
            await backupMetaFile.rename(metaFile.path);
          } catch (_) {}
        }
        debugPrint('Не удалось атомарно записать meta-файл: $e');
      }
    } catch (e) {
      if (e is SubscriptionException) rethrow;
      throw SubscriptionException(
        s.tr(
          'Ошибка при обновлении подписки: $e',
          'Error while updating subscription: $e',
          '更新订阅时出错：$e',
        ),
      );
    } finally {
      client.close();
    }
  }

  // ─── Разбор отдельных ссылок прокси ───

  /// Разбирает одну ссылку прокси и возвращает ProxyElement. Поддерживаемые
  /// схемы: vless, vmess, ss, trojan, hysteria2/hy2, tuic, wg/wireguard,
  /// socks/socks5, http. Для неподдерживаемых бросает FormatException.
  ProxyElement _parseProxyUri(String rawUrl) {
    final int hashIndex = rawUrl.indexOf('#');
    final String urlWithoutFragment =
        hashIndex != -1 ? rawUrl.substring(0, hashIndex) : rawUrl;
    final String fragment =
        hashIndex != -1 ? rawUrl.substring(hashIndex + 1) : '';

    final int ssSchemeSep = urlWithoutFragment.indexOf('://');
    final String earlyScheme = ssSchemeSep != -1
        ? urlWithoutFragment.substring(0, ssSchemeSep).toLowerCase()
        : '';
    if (earlyScheme == 'ss') {
      final String ssName =
          fragment.isEmpty ? 'SS_Node' : _safeUrlDecode(fragment).trim();
      return _parseShadowsocksUri(urlWithoutFragment, ssName);
    }

    final Uri uri = Uri.parse(urlWithoutFragment.trim());
    final String scheme = uri.scheme.toLowerCase();

    final String name = fragment.isEmpty
        ? '${scheme.toUpperCase()}_Node'
        : _safeUrlDecode(fragment).trim();
    final int targetPort = uri.port != 0 ? uri.port : 443;

    if (scheme == 'vless') {
      return ProxyElement(
        protocolType: 'vless',
        name: name,
        uuid: uri.userInfo,
        server: uri.host,
        port: targetPort,
        network: uri.queryParameters['type'] ??
            uri.queryParameters['network'] ??
            'tcp',
        security: uri.queryParameters['security'] ?? 'none',
        sni: uri.queryParameters['sni'] ?? '',
        path: _safeUrlDecode(
          uri.queryParameters['path'] ?? uri.queryParameters['serviceName'],
        ),
        host: _safeUrlDecode(uri.queryParameters['host']),
        publicKey: uri.queryParameters['pbk'] ?? '',
        shortId: uri.queryParameters['sid'] ?? '',
        fingerprint: uri.queryParameters['fp'] ?? 'chrome',
        flow: uri.queryParameters['flow'] ?? '',
        allowInsecure: _parseInsecureFlag(uri.queryParameters),
      );
    } else if (scheme == 'wg' || scheme == 'wireguard') {
      return ProxyElement(
        protocolType: 'wireguard',
        name: name,
        uuid: uri.userInfo,
        server: uri.host,
        port: uri.port != 0 ? uri.port : 51820,
        publicKey: uri.queryParameters['public_key'] ??
            uri.queryParameters['pk'] ??
            '',
        path: uri.queryParameters['ip'] ??
            uri.queryParameters['address'] ??
            '10.0.0.2/32',
        shortId: uri.queryParameters['reserved'] ?? '',
      );
    } else if (scheme == 'socks' || scheme == 'socks5' || scheme == 'http') {
      String user = '';
      String pass = '';
      if (uri.userInfo.contains(':')) {
        final parts = uri.userInfo.split(':');
        user = parts[0];
        pass = parts.sublist(1).join(':');
      } else {
        user = uri.userInfo;
      }
      return ProxyElement(
        protocolType: scheme.startsWith('socks') ? 'socks5' : 'http',
        name: name,
        server: uri.host,
        port: uri.port != 0 ? uri.port : 1080,
        uuid: pass,
        cipher: user,
      );
    } else if (scheme == 'trojan') {
      return ProxyElement(
        protocolType: 'trojan',
        name: name,
        uuid: uri.userInfo,
        server: uri.host,
        port: targetPort,
        network: uri.queryParameters['type'] ??
            uri.queryParameters['network'] ??
            'tcp',
        security: uri.queryParameters['security'] ?? 'tls',
        sni: uri.queryParameters['sni'] ?? '',
        path: _safeUrlDecode(
          uri.queryParameters['path'] ?? uri.queryParameters['serviceName'],
        ),
        host: _safeUrlDecode(uri.queryParameters['host']),
        allowInsecure: _parseInsecureFlag(uri.queryParameters),
      );
    } else if (scheme == 'hysteria2' || scheme == 'hy2') {
      return ProxyElement(
        protocolType: 'hysteria2',
        name: name,
        uuid: uri.userInfo,
        server: uri.host,
        port: targetPort,
        sni: uri.queryParameters['sni'] ?? '',
        obfs: uri.queryParameters['obfs'] ?? '',
        obfsPassword: _safeUrlDecode(
          uri.queryParameters['obfs-password'] ??
              uri.queryParameters['obfs_password'],
        ),
        ports:
            uri.queryParameters['mport'] ?? uri.queryParameters['ports'] ?? '',
        allowInsecure: _parseInsecureFlag(uri.queryParameters),
      );
    } else if (scheme == 'tuic') {
      String uuid = uri.userInfo;
      String token = '';
      if (uri.userInfo.contains(':')) {
        final parts = uri.userInfo.split(':');
        uuid = parts[0];
        token = parts.sublist(1).join(':');
      }
      return ProxyElement(
        protocolType: 'tuic',
        name: name,
        uuid: uuid,
        cipher: token,
        server: uri.host,
        port: targetPort,
        sni: uri.queryParameters['sni'] ?? '',
        fingerprint: uri.queryParameters['fp'] ?? 'chrome',
        allowInsecure: _parseInsecureFlag(uri.queryParameters),
      );
    } else if (scheme == 'vmess') {
      final int index = rawUrl.indexOf('://');
      if (index == -1) throw const FormatException('Неверный VMess URI');

      String base64part = rawUrl.substring(index + 3).split('#')[0].trim();
      final decoded = jsonDecode(_safeBase64Decode(base64part));
      if (decoded is! Map) {
        throw const FormatException('Невалидный JSON узел VMess');
      }

      return ProxyElement(
        protocolType: 'vmess',
        name: decoded['ps']?.toString() ?? name,
        uuid: decoded['id']?.toString() ?? '',
        server: decoded['add']?.toString() ?? '',
        port: int.tryParse(decoded['port']?.toString() ?? '443') ?? 443,
        alterId: int.tryParse(decoded['aid']?.toString() ?? '0') ?? 0,
        network: decoded['net']?.toString() ?? 'tcp',
        security: (decoded['tls'] == true ||
                decoded['tls']?.toString().toLowerCase() == 'tls' ||
                decoded['tls']?.toString().toLowerCase() == 'true')
            ? 'tls'
            : 'none',
        sni: decoded['sni']?.toString() ?? decoded['host']?.toString() ?? '',
        path: decoded['path']?.toString() ?? '',
        host: decoded['host']?.toString() ?? '',
        cipher: decoded['scy']?.toString() ?? 'auto',
        allowInsecure: decoded['allowInsecure'] == true ||
            _isInsecureValue(decoded['allowInsecure']?.toString()) ||
            decoded['verify_cert']?.toString().toLowerCase() == 'false',
      );
    }

    throw const FormatException('Неподдерживаемый сетевой протокол');
  }

  /// Разбирает Shadowsocks-ссылку в двух форматах: устаревшем (всё тело —
  /// Base64 от method:password@host:port) и SIP002.
  ProxyElement _parseShadowsocksUri(String urlWithoutFragment, String name) {
    final int schemeIdx = urlWithoutFragment.indexOf('://');
    final String body = (schemeIdx != -1
            ? urlWithoutFragment.substring(schemeIdx + 3)
            : urlWithoutFragment)
        .trim();

    String cipher = 'chacha20-ietf-poly1305';
    String password = '';
    String host = '';
    int port = 8388;

    final int atIdx = body.lastIndexOf('@');
    if (atIdx == -1) {
      // Устаревший формат: всё тело — это Base64 от method:password@host:port.
      final String decoded = _safeBase64Decode(body);
      final int dAt = decoded.lastIndexOf('@');
      if (dAt == -1) throw const FormatException('Invalid SS URI');
      final String cred = decoded.substring(0, dAt);
      final int cColon = cred.indexOf(':');
      if (cColon == -1) throw const FormatException('Invalid SS URI');
      cipher = cred.substring(0, cColon);
      password = cred.substring(cColon + 1);
      final (String h, int pt) = _splitHostPort(decoded.substring(dAt + 1));
      host = h;
      port = pt;
    } else {
      // Формат SIP002: ss://base64(method:pass)@host:port[?plugin=...]
      final String userPart = body.substring(0, atIdx);
      String hostPort = body.substring(atIdx + 1);
      final int qIdx = hostPort.indexOf('?');
      if (qIdx != -1) {
        // Плагины SIP002 (obfs / v2ray-plugin) не переносятся в генерируемый
        // Clash YAML, поэтому импорт такого узла как обычного Shadowsocks дал
        // бы молча неработающий прокси. Отклоняем его, чтобы он считался
        // пропущенным, а не ложно «рабочим».
        final String query = hostPort.substring(qIdx + 1).toLowerCase();
        hostPort = hostPort.substring(0, qIdx);
        if (query.contains('plugin=')) {
          throw const FormatException('Shadowsocks plugin not supported');
        }
      }

      String creds = userPart;
      if (!userPart.contains(':')) {
        try {
          creds = _safeBase64Decode(userPart);
        } catch (_) {
          creds = userPart;
        }
      }
      final int cColon = creds.indexOf(':');
      if (cColon != -1) {
        cipher = creds.substring(0, cColon);
        password = creds.substring(cColon + 1);
      } else {
        password = creds;
      }
      final (String h, int pt) = _splitHostPort(hostPort);
      host = h;
      port = pt;
    }

    if (host.isEmpty) throw const FormatException('Invalid SS URI');

    return ProxyElement(
      protocolType: 'ss',
      name: name,
      uuid: password,
      cipher: cipher,
      server: host,
      port: port != 0 ? port : 8388,
    );
  }

  /// Разбивает строку «хост:порт» на пару, корректно обрабатывая IPv6 в
  /// квадратных скобках. Порт по умолчанию — 8388.
  (String, int) _splitHostPort(String input) {
    final String hp = input.trim();
    if (hp.startsWith('[')) {
      final int close = hp.indexOf(']');
      if (close != -1) {
        final String addr = hp.substring(1, close);
        final String rest = hp.substring(close + 1);
        if (rest.startsWith(':')) {
          return (addr, int.tryParse(rest.substring(1)) ?? 8388);
        }
        return (addr, 8388);
      }
    }
    final int colon = hp.lastIndexOf(':');
    if (colon != -1) {
      final int? parsed = int.tryParse(hp.substring(colon + 1));
      if (parsed != null) {
        return (hp.substring(0, colon), parsed);
      }
    }
    return (hp, 8388);
  }

  // ─── Сборка итогового YAML-конфига ───

  /// Ключи верхнего уровня, которые JustClash переопределяет своими
  /// значениями и потому вырезает из исходного конфига провайдера.
  static const Set<String> _overriddenTopKeys = {
    'external-controller',
    'secret',
    'external-ui',
    'port',
    'socks-port',
    'mixed-port',
    'allow-lan',
    'log-level',
    'mode',
    'tun',
    'ipv6',
    'unified-delay',
    'tcp-concurrent',
    'geodata-mode',
    'geo-auto-update',
    'geo-update-interval',
    'geox-url',
  };

  /// Возвращает true, если строка — это ключ верхнего уровня YAML (без
  /// отступа, не комментарий и не элемент списка).
  bool _isTopLevelKeyLine(String line) {
    if (line.isEmpty) return false;
    final int first = line.codeUnitAt(0);
    if (first == 0x20 || first == 0x09 || first == 0x23 || first == 0x2D) {
      return false;
    }
    return RegExp(r'^([^:#\s][^:]*):(\s|$)').hasMatch(line);
  }

  /// Удаляет из исходного YAML заданные ключи верхнего уровня вместе с их
  /// вложенными блоками, сохраняя остальное без изменений.
  String _stripTopLevelKeys(String raw, Set<String> keys) {
    final List<String> lines = raw.split('\n');
    final List<String> out = [];
    bool skipping = false;
    for (final line in lines) {
      if (_isTopLevelKeyLine(line)) {
        final String key = RegExp(
          r'^([^:#\s][^:]*):',
        ).firstMatch(line)!.group(1)!.trim();
        if (keys.contains(key)) {
          skipping = true;
          continue;
        }
        skipping = false;
        out.add(line);
      } else if (line.isNotEmpty && line.codeUnitAt(0) == 0x23) {
        skipping = false;
        out.add(line);
      } else {
        if (skipping) continue;
        out.add(line);
      }
    }
    return out.join('\n');
  }

  /// Дополняет готовый Clash-конфиг провайдера обязательными секциями
  /// JustClash (контроллер, порт, tun, dns, geo) и добавляет стандартные
  /// proxy-groups/rules, если их нет в исходнике.
  String _patchProviderClashConfig(String raw, YamlMap parsed) {
    final bool hasGroups = parsed['proxy-groups'] is YamlList &&
        (parsed['proxy-groups'] as YamlList).isNotEmpty;
    final bool hasRules =
        parsed['rules'] is YamlList && (parsed['rules'] as YamlList).isNotEmpty;
    final bool hasDns = parsed['dns'] != null;
    final bool hasProfile = parsed['profile'] != null;
    final bool hasFingerprint = parsed['global-client-fingerprint'] != null;

    final String body = _stripTopLevelKeys(raw, _overriddenTopKeys).trim();

    final StringBuffer header = StringBuffer();
    header.writeln('external-controller: 127.0.0.1:9090');
    header.writeln('secret: "${SettingsService().apiSecret}"');
    header.writeln('mixed-port: 7893');
    header.writeln('allow-lan: false');
    header.writeln('mode: rule');
    header.writeln('log-level: silent');
    header.writeln('unified-delay: true');
    header.writeln('tcp-concurrent: true');
    header.writeln('geodata-mode: true');
    header.writeln('geo-auto-update: true');
    header.writeln('geo-update-interval: 24');
    header.writeln(
      'geox-url: { geoip: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat", geosite: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat", mmdb: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb", asn: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb" }',
    );
    header.writeln(
      'tun: { enable: false, stack: gvisor, auto-route: true, auto-detect-interface: true, dns-hijack: ["any:53"] }',
    );
    header.writeln('ipv6: false');
    if (!hasFingerprint) {
      header.writeln('global-client-fingerprint: chrome');
    }
    if (!hasDns) {
      header.writeln(
        'dns: { enable: true, enhanced-mode: fake-ip, listen: "127.0.0.1:1053", fake-ip-filter: ["*.lan", "*.local", "+.msftconnecttest.com", "+.msftncsi.com", "localhost.ptlogin2.qq.com", "+.stun.*.*", "time.windows.com", "+.pool.ntp.org"], default-nameserver: ["1.1.1.1", "8.8.8.8"], proxy-server-nameserver: ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"], nameserver: ["https://dns.google/dns-query", "https://cloudflare-dns.com/dns-query", "1.1.1.1", "8.8.8.8"] }',
      );
    }
    if (!hasProfile) {
      header.writeln('profile: { store-selected: true, store-fake-ip: false }');
    }

    final StringBuffer out = StringBuffer();
    out.write(header.toString());
    out.writeln();
    out.writeln(body);

    if (!hasGroups) {
      final List<String> proxyNames = [];
      final dynamic pNode = parsed['proxies'];
      if (pNode is YamlList) {
        for (final pr in pNode) {
          if (pr is YamlMap && pr['name'] != null) {
            proxyNames.add(pr['name'].toString());
          }
        }
      }
      out.writeln();
      out.writeln('proxy-groups:');
      out.writeln('  - name: PROXY');
      out.writeln('    type: select');
      out.writeln('    proxies:');
      for (final String n in proxyNames) {
        out.writeln('      - ${_escapeYamlValue(n)}');
      }
      out.writeln('      - DIRECT');
    }
    if (!hasRules) {
      out.writeln();
      out.writeln('rules:');
      out.writeln('  - GEOIP,LAN,DIRECT,no-resolve');
      out.writeln('  - MATCH,PROXY');
    }
    return out.toString();
  }

  /// Заключает значение в кавычки и экранирует спецсимволы YAML, если строка
  /// содержит потенциально опасные символы.
  String _escapeYamlValue(dynamic value) {
    if (value == null) return 'null';
    if (value is bool || value is num) return value.toString();
    final str = value.toString();

    if (str.contains('\n') ||
        str.contains('\r') ||
        str.contains('\t') ||
        str.contains(':') ||
        str.contains('"') ||
        str.contains("'") ||
        str.contains('#') ||
        str.contains('[') ||
        str.contains(']') ||
        str.contains('{') ||
        str.contains('}') ||
        str.contains(',') ||
        str.contains('*') ||
        str.contains('&') ||
        str.startsWith(' ') ||
        str.endsWith(' ')) {
      return '"${str.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r').replaceAll('\t', '\\t')}"';
    }
    return str;
  }

  /// Собирает полный Clash YAML из списка распарсенных узлов: задаёт секции
  /// JustClash, перечисляет proxies с уникальными именами и формирует группу
  /// PROXY с базовыми правилами.
  String _buildClashYaml(List<ProxyElement> proxies) {
    final StringBuffer buffer = StringBuffer();
    buffer.writeln(
      'tun: { enable: false, stack: gvisor, auto-route: true, auto-detect-interface: true, dns-hijack: ["any:53"] }',
    );
    buffer.writeln('ipv6: false');
    buffer.writeln('external-controller: 127.0.0.1:9090');
    buffer.writeln('secret: "${SettingsService().apiSecret}"');
    buffer.writeln('mixed-port: 7893');
    buffer.writeln('allow-lan: false');
    buffer.writeln('mode: direct');
    buffer.writeln('log-level: silent');
    // Для raw-профилей измерение задержки делаем честным HTTP-замером:
    // unified-delay отключён, поэтому Core API (HTTP) учитывает установление
    // соединения (TCP + TLS + первый ответ) и заметно отличается от чистого
    // TCP-замера хендшейка. При unified-delay: true ядро намеренно убирает
    // время хендшейка из результата, из-за чего значения Core API и TCP
    // получались почти одинаковыми. Группа PROXY здесь типа select (без
    // авто-url-test), поэтому отключение ни на что в маршрутизации не влияет.
    buffer.writeln('unified-delay: false');
    buffer.writeln('tcp-concurrent: true');
    buffer.writeln('global-client-fingerprint: chrome');
    buffer.writeln('geodata-mode: true');
    buffer.writeln('geo-auto-update: true');
    buffer.writeln('geo-update-interval: 24');
    buffer.writeln(
      'geox-url: { geoip: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat", geosite: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat", mmdb: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb", asn: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb" }',
    );
    buffer.writeln(
      'dns: { enable: true, enhanced-mode: fake-ip, listen: "127.0.0.1:1053", fake-ip-filter: ["*.lan", "*.local", "+.msftconnecttest.com", "+.msftncsi.com", "localhost.ptlogin2.qq.com", "+.stun.*.*", "time.windows.com", "+.pool.ntp.org"], default-nameserver: ["1.1.1.1", "8.8.8.8"], proxy-server-nameserver: ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"], nameserver: ["https://dns.google/dns-query", "https://cloudflare-dns.com/dns-query", "1.1.1.1", "8.8.8.8"] }',
    );
    buffer.writeln('profile: { store-selected: true, store-fake-ip: false }');
    buffer.writeln('\nproxies:');

    final List<String> proxyNames = [];
    final Set<String> seenNames = {};

    for (final proxy in proxies) {
      String escapedName = _sanitizeYamlString(proxy.name);
      if (escapedName.isEmpty) escapedName = "Proxy";
      if (escapedName.toUpperCase() == 'PROXY' ||
          escapedName.toUpperCase() == 'DIRECT') {
        escapedName = "${escapedName}_Node";
      }

      String uniqueName = escapedName;
      int counter = 1;
      while (seenNames.contains(uniqueName)) {
        uniqueName = "${escapedName}_$counter";
        counter++;
      }
      seenNames.add(uniqueName);
      proxyNames.add(uniqueName);

      buffer.writeln('  - name: "$uniqueName"');

      String safeServer = proxy.server.replaceAll('[', '').replaceAll(']', '');
      buffer.writeln('    server: "${_sanitizeYamlString(safeServer)}"');
      buffer.writeln('    port: ${proxy.port}');
      buffer.writeln('    udp: true');

      if (proxy.protocolType == 'vless') {
        buffer.writeln('    type: vless');
        buffer.writeln('    uuid: "${_sanitizeYamlString(proxy.uuid)}"');

        if (proxy.flow.isNotEmpty) {
          buffer.writeln('    flow: "${_sanitizeYamlString(proxy.flow)}"');
        }

        if (proxy.security == 'tls' ||
            proxy.security == 'reality' ||
            proxy.flow.contains('vision')) {
          buffer.writeln('    tls: true');
          if (proxy.sni.isNotEmpty) {
            buffer
                .writeln('    servername: "${_sanitizeYamlString(proxy.sni)}"');
          }
          if (proxy.fingerprint.isNotEmpty) {
            buffer.writeln(
              '    client-fingerprint: "${_sanitizeYamlString(proxy.fingerprint)}"',
            );
          }
          if (proxy.security == 'reality') {
            buffer.writeln(
              '    reality-opts: { public-key: "${_sanitizeYamlString(proxy.publicKey)}", short-id: "${_sanitizeYamlString(proxy.shortId)}" }',
            );
          }
        } else {
          buffer.writeln('    tls: false');
        }

        if (proxy.network != 'tcp' && proxy.network.isNotEmpty) {
          buffer.writeln(
            '    network: "${_sanitizeYamlString(proxy.network)}"',
          );
        }
        if (proxy.network == 'ws') {
          final safePath =
              proxy.path.isNotEmpty ? _sanitizeYamlString(proxy.path) : '/';
          if (proxy.host.isNotEmpty) {
            buffer.writeln(
              '    ws-opts: { path: "$safePath", headers: { Host: "${_sanitizeYamlString(proxy.host)}" } }',
            );
          } else {
            buffer.writeln('    ws-opts: { path: "$safePath" }');
          }
        } else if (proxy.network == 'grpc') {
          buffer.writeln(
            '    grpc-opts: { grpc-service-name: "${_sanitizeYamlString(proxy.path)}" }',
          );
        } else if (proxy.network == 'http') {
          buffer.writeln(
            '    http-opts: { path: ["${_sanitizeYamlString(proxy.path)}"], headers: { Host: "${_sanitizeYamlString(proxy.host)}" } }',
          );
        }
        buffer.writeln('    skip-cert-verify: ${proxy.allowInsecure}');
      } else if (proxy.protocolType == 'wireguard') {
        buffer.writeln('    type: wireguard');
        buffer.writeln('    private-key: "${_sanitizeYamlString(proxy.uuid)}"');
        buffer.writeln(
          '    public-key: "${_sanitizeYamlString(proxy.publicKey)}"',
        );

        final String rawIp = _sanitizeYamlString(proxy.path);
        if (rawIp.contains(',')) {
          final List<String> addresses = rawIp.split(',').map((e) {
            final String clean = e.trim();
            return '"${clean.contains('/') ? clean : "$clean/32"}"';
          }).toList();
          buffer.writeln('    ip: [${addresses.join(', ')}]');
        } else {
          buffer.writeln(
            '    ip: "${rawIp.contains('/') ? rawIp : "$rawIp/32"}"',
          );
        }

        if (proxy.shortId.isNotEmpty) {
          final List<int> parsedBytes = proxy.shortId
              .split(',')
              .map((e) => int.tryParse(e.trim()))
              .whereType<int>()
              .toList();
          if (parsedBytes.isNotEmpty) {
            buffer.writeln('    reserved: [${parsedBytes.join(', ')}]');
          }
        }
      } else if (proxy.protocolType == 'socks5' ||
          proxy.protocolType == 'http') {
        buffer.writeln('    type: ${proxy.protocolType}');
        if (proxy.cipher.isNotEmpty) {
          buffer.writeln(
            '    username: "${_sanitizeYamlString(proxy.cipher)}"',
          );
        }
        if (proxy.uuid.isNotEmpty) {
          buffer.writeln('    password: "${_sanitizeYamlString(proxy.uuid)}"');
        }
      } else if (proxy.protocolType == 'vmess') {
        buffer.writeln('    type: vmess');
        buffer.writeln('    uuid: "${_sanitizeYamlString(proxy.uuid)}"');
        buffer.writeln('    alterId: ${proxy.alterId}');
        buffer.writeln(
          '    cipher: "${proxy.cipher.isNotEmpty ? _sanitizeYamlString(proxy.cipher) : 'auto'}"',
        );
        if (proxy.security == 'tls') {
          buffer.writeln('    tls: true');
          if (proxy.sni.isNotEmpty) {
            buffer
                .writeln('    servername: "${_sanitizeYamlString(proxy.sni)}"');
          }
        }
        if (proxy.network != 'tcp' && proxy.network.isNotEmpty) {
          buffer.writeln(
            '    network: "${_sanitizeYamlString(proxy.network)}"',
          );
        }
        if (proxy.network == 'ws') {
          final safePath =
              proxy.path.isNotEmpty ? _sanitizeYamlString(proxy.path) : '/';
          if (proxy.host.isNotEmpty) {
            buffer.writeln(
              '    ws-opts: { path: "$safePath", headers: { Host: "${_sanitizeYamlString(proxy.host)}" } }',
            );
          } else {
            buffer.writeln('    ws-opts: { path: "$safePath" }');
          }
        } else if (proxy.network == 'grpc') {
          buffer.writeln(
            '    grpc-opts: { grpc-service-name: "${_sanitizeYamlString(proxy.path)}" }',
          );
        } else if (proxy.network == 'h2') {
          final safePath =
              proxy.path.isNotEmpty ? _sanitizeYamlString(proxy.path) : '/';
          if (proxy.host.isNotEmpty) {
            buffer.writeln(
              '    h2-opts: { host: ["${_sanitizeYamlString(proxy.host)}"], path: "$safePath" }',
            );
          } else {
            buffer.writeln('    h2-opts: { path: "$safePath" }');
          }
        } else if (proxy.network == 'http') {
          final safePath =
              proxy.path.isNotEmpty ? _sanitizeYamlString(proxy.path) : '/';
          if (proxy.host.isNotEmpty) {
            buffer.writeln(
              '    http-opts: { path: ["$safePath"], headers: { Host: "${_sanitizeYamlString(proxy.host)}" } }',
            );
          } else {
            buffer.writeln('    http-opts: { path: ["$safePath"] }');
          }
        }
        buffer.writeln('    skip-cert-verify: ${proxy.allowInsecure}');
      } else if (proxy.protocolType == 'trojan') {
        buffer.writeln('    type: trojan');
        buffer.writeln('    password: "${_sanitizeYamlString(proxy.uuid)}"');
        if (proxy.security == 'tls' || proxy.security.isEmpty) {
          buffer.writeln('    tls: true');
          if (proxy.sni.isNotEmpty) {
            buffer.writeln('    sni: "${_sanitizeYamlString(proxy.sni)}"');
          } else {
            buffer.writeln('    sni: "${_sanitizeYamlString(safeServer)}"');
          }
        }
        if (proxy.network != 'tcp' && proxy.network.isNotEmpty) {
          buffer.writeln(
            '    network: "${_sanitizeYamlString(proxy.network)}"',
          );
        }
        if (proxy.network == 'ws') {
          final safePath =
              proxy.path.isNotEmpty ? _sanitizeYamlString(proxy.path) : '/';
          if (proxy.host.isNotEmpty) {
            buffer.writeln(
              '    ws-opts: { path: "$safePath", headers: { Host: "${_sanitizeYamlString(proxy.host)}" } }',
            );
          } else {
            buffer.writeln('    ws-opts: { path: "$safePath" }');
          }
        } else if (proxy.network == 'grpc') {
          buffer.writeln(
            '    grpc-opts: { grpc-service-name: "${_sanitizeYamlString(proxy.path)}" }',
          );
        }
        buffer.writeln('    skip-cert-verify: ${proxy.allowInsecure}');
      } else if (proxy.protocolType == 'ss') {
        buffer.writeln('    type: ss');
        buffer.writeln('    cipher: "${_sanitizeYamlString(proxy.cipher)}"');
        buffer.writeln('    password: "${_sanitizeYamlString(proxy.uuid)}"');
      } else if (proxy.protocolType == 'hysteria2') {
        buffer.writeln('    type: hysteria2');
        buffer.writeln('    password: "${_sanitizeYamlString(proxy.uuid)}"');
        if (proxy.sni.isNotEmpty) {
          buffer.writeln('    sni: "${_sanitizeYamlString(proxy.sni)}"');
        }
        if (proxy.obfs.isNotEmpty) {
          buffer.writeln('    obfs: "${_sanitizeYamlString(proxy.obfs)}"');
          if (proxy.obfsPassword.isNotEmpty) {
            buffer.writeln(
              '    obfs-password: "${_sanitizeYamlString(proxy.obfsPassword)}"',
            );
          }
        }
        if (proxy.ports.isNotEmpty) {
          buffer.writeln('    ports: "${_sanitizeYamlString(proxy.ports)}"');
        }
        buffer.writeln('    skip-cert-verify: ${proxy.allowInsecure}');
      } else if (proxy.protocolType == 'tuic') {
        buffer.writeln('    type: tuic');
        buffer.writeln('    uuid: "${_sanitizeYamlString(proxy.uuid)}"');
        if (proxy.cipher.isNotEmpty) {
          buffer.writeln(
            '    password: "${_sanitizeYamlString(proxy.cipher)}"',
          );
        }
        if (proxy.sni.isNotEmpty) {
          buffer.writeln('    sni: "${_sanitizeYamlString(proxy.sni)}"');
        }
        if (proxy.fingerprint.isNotEmpty) {
          buffer.writeln(
            '    client-fingerprint: "${_sanitizeYamlString(proxy.fingerprint)}"',
          );
        }
        buffer.writeln('    alpn: [h3]');
        buffer.writeln('    disable-sni: false');
        buffer.writeln('    reduce-rtt: true');
        buffer.writeln('    skip-cert-verify: ${proxy.allowInsecure}');
      }
    }

    buffer.writeln('\nproxy-groups:');
    buffer.writeln('  - name: PROXY\n    type: select\n    proxies:');
    for (final name in proxyNames) {
      buffer.writeln('      - "$name"');
    }
    buffer.writeln(
      '      - DIRECT\n\nrules:\n  - GEOIP,LAN,DIRECT,no-resolve\n  - MATCH,PROXY',
    );
    return buffer.toString();
  }
}
