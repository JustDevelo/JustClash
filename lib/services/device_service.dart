import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// ═══════════════════════════════════════════════════════════════════════════
//  DeviceService / DeviceInfoData
//  Сбор аппаратного идентификатора (HWID) и сведений об устройстве
//  для заголовков запроса подписки (x-hwid, x-device-os, x-ver-os, x-device-model).
//
//  На Windows HWID берётся из реестра (MachineGuid); при неудаче генерируется
//  и сохраняется постоянный UUIDv4 в файле. Результат кэшируется на время сессии.
// ═══════════════════════════════════════════════════════════════════════════

/// Неизменяемый снимок сведений об устройстве.
class DeviceInfoData {
  final String hwid;
  final String os;
  final String osVersion;
  final String model;
  final String computerName;

  const DeviceInfoData({
    required this.hwid,
    required this.os,
    required this.osVersion,
    required this.model,
    required this.computerName,
  });
}

/// Сервис-синглтон: определяет и кэширует сведения об устройстве.
class DeviceService {
  // ──────────────── Синглтон и кэш ────────────────
  DeviceService._internal();
  static final DeviceService _instance = DeviceService._internal();
  factory DeviceService() => _instance;

  DeviceInfoData? _cached;
  Future<DeviceInfoData>? _loading;

  // ──────────────── Публичный API ────────────────

  /// Вернуть сведения об устройстве из кэша или запустить однократную загрузку.
  Future<DeviceInfoData> getInfo() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load();
  }

  /// Сформировать HTTP-заголовки устройства для запроса подписки.
  /// При ошибке возвращает пустую карту (заголовки не критичны).
  Future<Map<String, String>> getSubscriptionHeaders() async {
    try {
      final info = await getInfo();
      final headers = <String, String>{};
      final String hwid = _sanitizeHeaderValue(info.hwid);
      final String os = _sanitizeHeaderValue(info.os);
      final String osVersion = _sanitizeHeaderValue(info.osVersion);
      final String model = _sanitizeHeaderValue(info.model);
      if (hwid.isNotEmpty) headers['x-hwid'] = hwid;
      if (os.isNotEmpty) headers['x-device-os'] = os;
      if (osVersion.isNotEmpty) headers['x-ver-os'] = osVersion;
      if (model.isNotEmpty) headers['x-device-model'] = model;
      return headers;
    } catch (e) {
      debugPrint(
        '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0441\u0444\u043e\u0440\u043c\u0438\u0440\u043e\u0432\u0430\u0442\u044c HWID-\u0437\u0430\u0433\u043e\u043b\u043e\u0432\u043a\u0438: $e',
      );
      return {};
    }
  }

  /// Оставить только печатные ASCII-символы (0x20..0x7E): значения
  /// HTTP-заголовков не должны содержать не-ASCII и управляющих символов.
  String _sanitizeHeaderValue(String value) {
    final buffer = StringBuffer();
    for (final code in value.codeUnits) {
      if (code >= 0x20 && code <= 0x7E) buffer.writeCharCode(code);
    }
    return buffer.toString().trim();
  }

  // ──────────── Внутренняя загрузка данных ────────────

  /// Однократно собрать сведения об устройстве (реестр Windows либо запасной путь).
  Future<DeviceInfoData> _load() async {
    String hwid = '';
    String osVersion = '';
    String model = '';
    String computerName = '';

    try {
      computerName = Platform.localHostname;
    } catch (_) {}

    if (Platform.isWindows) {
      hwid = _normalizeHwid(
        await _readRegistryValue(
          r'HKLM\SOFTWARE\Microsoft\Cryptography',
          'MachineGuid',
        ),
      );

      final productName = await _readRegistryValue(
        r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
        'ProductName',
      );
      final displayVersion = await _readRegistryValue(
        r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
        'DisplayVersion',
      );
      final currentBuild = await _readRegistryValue(
        r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
        'CurrentBuild',
      );
      final manufacturer = await _readRegistryValue(
        r'HKLM\HARDWARE\DESCRIPTION\System\BIOS',
        'SystemManufacturer',
      );
      final systemProduct = await _readRegistryValue(
        r'HKLM\HARDWARE\DESCRIPTION\System\BIOS',
        'SystemProductName',
      );

      final versionParts = <String>[];
      if (productName.isNotEmpty) versionParts.add(productName);
      if (displayVersion.isNotEmpty) {
        versionParts.add(displayVersion);
      } else if (currentBuild.isNotEmpty) {
        versionParts.add('build $currentBuild');
      }
      osVersion = versionParts.join(' ').trim();

      final modelParts = <String>[];
      if (manufacturer.isNotEmpty) modelParts.add(manufacturer);
      if (systemProduct.isNotEmpty) modelParts.add(systemProduct);
      model = modelParts.join(' ').trim();
    } else {
      try {
        osVersion = Platform.operatingSystemVersion;
      } catch (_) {}
    }

    if (model.isEmpty) model = computerName;
    if (hwid.isEmpty) hwid = await _loadOrCreatePersistentHwid();

    final info = DeviceInfoData(
      hwid: hwid,
      os: Platform.isWindows ? 'Windows' : Platform.operatingSystem,
      osVersion: osVersion,
      model: model,
      computerName: computerName,
    );
    _cached = info;
    return info;
  }

  /// Нормализовать HWID: убрать фигурные скобки и обрезать до 36 символов.
  String _normalizeHwid(String raw) {
    var value = raw.trim();
    if (value.startsWith('{') && value.endsWith('}')) {
      value = value.substring(1, value.length - 1);
    }
    if (value.length > 36) value = value.substring(0, 36);
    return value;
  }

  /// Прочитать значение из реестра Windows через `reg query`.
  /// Возвращает пустую строку при любой ошибке или отсутствии значения.
  Future<String> _readRegistryValue(String keyPath, String valueName) async {
    try {
      final result = await Process.run(
          'reg',
          [
            'query',
            keyPath,
            '/v',
            valueName,
          ],
          runInShell: false);
      if (result.exitCode != 0) return '';
      final out = result.stdout.toString();
      for (final line in const LineSplitter().convert(out)) {
        if (!line.toLowerCase().contains(valueName.toLowerCase())) continue;
        final match = RegExp(r'REG_\w+').firstMatch(line);
        if (match == null) continue;
        return line.substring(match.end).trim();
      }
      return '';
    } catch (e) {
      debugPrint(
        '\u041e\u0448\u0438\u0431\u043a\u0430 \u0447\u0442\u0435\u043d\u0438\u044f \u0440\u0435\u0435\u0441\u0442\u0440\u0430 ($keyPath\\$valueName): $e',
      );
      return '';
    }
  }

  /// Загрузить ранее сохранённый запасной HWID или создать и сохранить новый.
  Future<String> _loadOrCreatePersistentHwid() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'JustClash', 'device_hwid.txt'));
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (existing.isNotEmpty) return existing;
      }
      final generated = _generateUuidV4();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(generated, flush: true);
      return generated;
    } catch (e) {
      debugPrint(
        '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0441\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c \u0440\u0435\u0437\u0435\u0440\u0432\u043d\u044b\u0439 HWID: $e',
      );
      return _generateUuidV4();
    }
  }

  /// Сгенерировать UUIDv4 на криптостойком ГПСЧ (вариант RFC 4122).
  String _generateUuidV4() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) {
      final sb = StringBuffer();
      for (var i = start; i < end; i++) {
        sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
      }
      return sb.toString();
    }

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}
