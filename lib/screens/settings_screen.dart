// ═══════════════════════════════════════════════════════════════════════════
// SettingsScreen — экран настроек системы.
//
// Назначение файла:
//   • Общие настройки: тема, акцент, стиль, язык, трей, автозапуск, автообновление.
//   • Компоненты: проверка актуальности ядра Mihomo и Geo-баз, ручное обновление.
//   • Устройство: HWID и сводка о системе.
// Статус компонентов сначала сверяется онлайн (GitHub Releases), иначе по локальным эвристикам.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../services/settings_service.dart';
import '../services/core_controller.dart';
import '../services/device_service.dart';
import '../services/theme_service.dart';
import '../widgets/animated_ellipsis_text.dart';

/// Экран «Настройки системы».
class SettingsScreen extends StatefulWidget {
  final CoreController coreController;
  const SettingsScreen({super.key, required this.coreController});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Состояние экрана настроек: версия ядра, статус компонентов и сведения об устройстве.
class _SettingsScreenState extends State<SettingsScreen> {
  // ─── Поля состояния ───

  final SettingsService _settings = SettingsService();
  bool _isUpdatingGeo = false;
  String _status = '';
  DeviceInfoData? _deviceInfo;
  String _coreVersion = '';

  // ─── Форматирование и подписи ───

  /// Подпись интервала авто-обновления подписки по числу часов.
  String _getAutoUpdateLabel(int hours) {
    switch (hours) {
      case 1:
        return _settings.tr('Каждый час', 'Every 1 hour', '每 1 小时');
      case 6:
        return _settings.tr('Каждые 6 часов', 'Every 6 hours', '每 6 小时');
      case 12:
        return _settings.tr('Каждые 12 часов', 'Every 12 hours', '每 12 小时');
      case 24:
        return _settings.tr('Раз в день', 'Daily', '每天');
      default:
        return _settings.tr('Отключено', 'Disabled', '已禁用');
    }
  }

  /// Подпись метода измерения пинга (TCP или Core API).
  String _getPingMethodLabel(String method) {
    if (method == 'tcp') {
      return 'TCP';
    } else {
      return 'Core API (HTTP)';
    }
  }

  /// Форматирует число байт в читаемую строку (B/KB/MB).
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final double kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final double mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  void initState() {
    super.initState();
    _settings.language.addListener(_onLanguageChanged);
    // Экран настроек создаётся заранее (IndexedStack в main.dart), поэтому
    // первичная проверка версии может отработать ДО того, как ядро поднимется
    // при холодном старте после перезагрузки. Подписываемся на isRunning, чтобы
    // перечитать версию из API ядра, как только оно станет запущенным.
    widget.coreController.isRunning.addListener(_onCoreRunningChanged);
    _initComponents();
    _loadDeviceInfo();
  }

  /// Сначала загружает версию ядра, затем проверяет статус компонентов.
  Future<void> _initComponents() async {
    // Гарантируем, что ядро уже извлечено на диск, ПЕРЕД чтением его версии.
    // При самом первом запуске ядро извлекается асинхронно, и _loadCoreVersion
    // мог отработать раньше — тогда версия пустая, и карточка показывала
    // запасной текст «Mihomo (Clash.Meta) · Windows x64», а реальная версия
    // появлялась лишь при повторном заходе в настройки. Извлекаем ядро здесь
    // (идемпотентно), чтобы версия читалась корректно с первого раза.
    await widget.coreController.ensureCoreExists();
    // Затем загружаем версию установленного ядра, чтобы _checkComponentsStatus
    // использовал её в вердикте, а не считал «актуальным» только по наличию
    // файла. Порядок важен: статус зависит от строки версии.
    await _loadCoreVersion();
    await _checkComponentsStatus();
  }

  @override
  void dispose() {
    _settings.language.removeListener(_onLanguageChanged);
    widget.coreController.isRunning.removeListener(_onCoreRunningChanged);
    super.dispose();
  }

  /// При смене языка перепроверяет статус компонентов.
  void _onLanguageChanged() {
    if (!mounted) return;
    _checkComponentsStatus();
  }

  /// Когда ядро поднялось (например, после автозапуска при холодном старте) и
  /// версия ещё не определена — перечитываем её. Это убирает баг, когда после
  /// перезагрузки карточка ядра застревала на запасном тексте «Mihomo
  /// (Clash.Meta) · Windows x64» до перезахода в приложение.
  void _onCoreRunningChanged() {
    if (!mounted) return;
    if (widget.coreController.isRunning.value && _coreVersion.isEmpty) {
      _loadCoreVersion();
    }
  }

  /// Загружает сведения об устройстве (модель, ОС, имя, HWID).
  Future<void> _loadDeviceInfo() async {
    final info = await DeviceService().getInfo();
    if (mounted) {
      setState(() {
        _deviceInfo = info;
      });
    }
  }

  // ─── Проверка актуальности ядра и Geo-баз ───

  /// Определяет версию ядра. Источники по приоритету:
  ///   1) REST API запущенного ядра (`GET /version`) — авторитетно и надёжно;
  ///   2) запуск бинарника с флагом -v (когда ядро ещё не поднято) — с
  ///      таймаутом и повторами, чтобы единичный сбой запуска процесса при
  ///      загрузке системы не оставлял версию пустой навсегда.
  Future<void> _loadCoreVersion() async {
    // 1) Версия из API запущенного ядра.
    try {
      final String? apiVersion =
          await widget.coreController.fetchCoreVersionFromApi();
      if (apiVersion != null && apiVersion.isNotEmpty) {
        final match = RegExp(r'v?\d+\.\d+\.\d+\S*').firstMatch(apiVersion);
        final String resolved = match?.group(0) ?? apiVersion;
        if (mounted && resolved.isNotEmpty) {
          setState(() => _coreVersion = resolved);
        }
        return;
      }
    } catch (_) {}

    // 2) Версия из бинарника (-v) с таймаутом и повторами.
    try {
      final corePath = await widget.coreController.getAbsoluteCorePath();
      if (!await File(corePath).exists()) return;
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          final result = await Process.run(corePath, ['-v'])
              .timeout(const Duration(seconds: 5));
          final String out = '${result.stdout}${result.stderr}'.trim();
          final match = RegExp(r'v?\d+\.\d+\.\d+\S*').firstMatch(out);
          if (match != null) {
            if (mounted) {
              setState(() => _coreVersion = match.group(0)!);
            }
            return;
          }
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 700));
      }
    } catch (_) {}
  }

  // Кэшируется, чтобы тяжёлое сравнение со встроенным ассетом выполнялось не более
  // одного раза за сессию (оно вообще выполняется, только когда онлайн-проверка
  // версии недоступна). Во Flutter нет API для чтения размера ассета без его
  // загрузки, поэтому кэш ограничивает эту разовую загрузку вместо повтора при
  // каждой перепроверке статуса.
  bool? _coreStaleCache;

  /// Возвращает кэшированный вердикт устаревания установленного ядра.
  Future<bool> _isInstalledCoreStale() async {
    if (_coreStaleCache != null) return _coreStaleCache!;
    final bool result = await _computeInstalledCoreStale();
    _coreStaleCache = result;
    return result;
  }

  // Сравниваем установленное ядро со встроенным побайтово. Вытащить строку
  // версии из сырого .exe-ассета нельзя, поэтому сравниваем размеры (затем
  // дешёвое сравнение нескольких байт). Встроенное ядро пересобирается только
  // когда приложение поставляет новый Mihomo, поэтому несовпадение размера
  // надёжно означает, что ядро на диске старше или новее ожидаемого этой сборкой.
  Future<bool> _computeInstalledCoreStale() async {
    try {
      final corePath = await widget.coreController.getAbsoluteCorePath();
      final installedFile = File(corePath);
      if (!await installedFile.exists()) return true;
      final int installedSize = await installedFile.length();
      if (installedSize < 1024 * 1024) return true;

      final assetData =
          await rootBundle.load('assets/core/mihomo-windows-amd64.exe');
      final int assetSize = assetData.lengthInBytes;
      if (installedSize != assetSize) return true;

      final Uint8List bundled = assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      );
      final int len = assetSize;
      // Выборочно проверяем 5 байт, не загружая всё ядро (~50 МБ) в память:
      // открываем установленный .exe как файл произвольного доступа и читаем
      // только те смещения, которые реально сравниваем.
      final raf = await installedFile.open();
      try {
        for (final i in [0, len ~/ 4, len ~/ 2, 3 * len ~/ 4, len - 1]) {
          await raf.setPosition(i);
          final int byte = (await raf.read(1)).first;
          if (byte != bundled[i]) return true;
        }
      } finally {
        await raf.close();
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Возраст самого старого локального Geo-файла в днях. База старше ~30 дней
  /// считается устаревшей и подлежит обновлению.
  Future<int> _oldestGeoDbAgeDays() async {
    try {
      final dir = await widget.coreController.getCurrentConfigDir();
      const names = [
        'geoip.dat',
        'geosite.dat',
        'geoip.metadb',
        'GeoLite2-ASN.mmdb',
      ];
      DateTime? oldest;
      for (final name in names) {
        final f = File(p.join(dir, name));
        if (!await f.exists() || await f.length() < 1024) return 365;
        final stat = await f.stat();
        final modified = stat.modified;
        if (oldest == null || modified.isBefore(oldest)) oldest = modified;
      }
      if (oldest == null) return 365;
      return DateTime.now().difference(oldest).inDays;
    } catch (_) {
      return 0;
    }
  }

  /// Время изменения самого старого Geo-файла; null, если какой-то отсутствует/пуст.
  Future<DateTime?> _oldestGeoDbModified() async {
    try {
      final dir = await widget.coreController.getCurrentConfigDir();
      const names = [
        'geoip.dat',
        'geosite.dat',
        'geoip.metadb',
        'GeoLite2-ASN.mmdb',
      ];
      DateTime? oldest;
      for (final name in names) {
        final f = File(p.join(dir, name));
        if (!await f.exists() || await f.length() < 1024) return null;
        final modified = (await f.stat()).modified;
        if (oldest == null || modified.isBefore(oldest)) oldest = modified;
      }
      return oldest;
    } catch (_) {
      return null;
    }
  }

  // ─── Онлайн-проверка свежести (через GitHub Releases) ───
  // Кэшируется, чтобы смена языка интерфейса не дёргала сеть на каждый вызов
  // _checkComponentsStatus. Каждая возвращает null при любой ошибке (нет сети,
  // лимит запросов, ошибка разбора), и тогда вызывающий код откатывается к
  // локальным эвристикам.
  String? _latestCoreVersion;
  bool _latestCoreFetched = false;
  DateTime? _latestGeoPublishedAt;
  bool _latestGeoFetched = false;

  /// Запрашивает последнюю версию ядра Mihomo с GitHub (с кэшированием).
  Future<String?> _fetchLatestCoreVersion() async {
    if (_latestCoreFetched) return _latestCoreVersion;
    _latestCoreFetched = true;
    try {
      final res = await http.get(
        Uri.parse(
          'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest',
        ),
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['tag_name'] is String) {
          _latestCoreVersion = (decoded['tag_name'] as String).trim();
        }
      }
    } catch (_) {}
    return _latestCoreVersion;
  }

  /// Запрашивает дату публикации последнего релиза Geo-баз с GitHub (с кэшем).
  Future<DateTime?> _fetchLatestGeoPublishedAt() async {
    if (_latestGeoFetched) return _latestGeoPublishedAt;
    _latestGeoFetched = true;
    try {
      final res = await http.get(
        Uri.parse(
          'https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/tags/latest',
        ),
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map) {
          final String? raw =
              (decoded['published_at'] ?? decoded['created_at'])?.toString();
          if (raw != null && raw.isNotEmpty) {
            _latestGeoPublishedAt = DateTime.tryParse(raw)?.toUtc();
          }
        }
      }
    } catch (_) {}
    return _latestGeoPublishedAt;
  }

  /// Сравнивает две semver-подобные строки (вроде «v1.18.9»); возвращает -1/0/1.
  int _compareVersions(String a, String b) {
    List<int> parse(String v) => v
        .replaceAll(RegExp(r'^[vV]'), '')
        .split(RegExp(r'[.\-+]'))
        .map((e) => int.tryParse(e) ?? -1)
        .where((e) => e >= 0)
        .toList();
    final pa = parse(a);
    final pb = parse(b);
    final int len = pa.length > pb.length ? pa.length : pb.length;
    for (int i = 0; i < len; i++) {
      final int x = i < pa.length ? pa[i] : 0;
      final int y = i < pb.length ? pb[i] : 0;
      if (x != y) return x < y ? -1 : 1;
    }
    return 0;
  }

  // ─── Устройство ───

  /// Копирует HWID в буфер обмена и показывает уведомление.
  void _copyHwid() {
    final hwid = _deviceInfo?.hwid ?? '';
    if (hwid.isEmpty) return;
    Clipboard.setData(ClipboardData(text: hwid));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _settings.tr(
            'HWID скопирован в буфер обмена',
            'HWID copied to clipboard',
            'HWID 已复制到剪贴板',
          ),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Краткая сводка об устройстве: модель, версия ОС и имя компьютера.
  String _deviceSummary() {
    final info = _deviceInfo;
    if (info == null) {
      return _settings.tr('Определение...', 'Detecting...', '检测中...');
    }
    final parts = <String>[];
    if (info.model.isNotEmpty) parts.add(info.model);
    if (info.osVersion.isNotEmpty) parts.add(info.osVersion);
    if (info.computerName.isNotEmpty) parts.add(info.computerName);
    return parts.isEmpty
        ? _settings.tr('Неизвестно', 'Unknown', '未知')
        : parts.join(' • ');
  }

  // ─── Сводный статус компонентов ───

  /// Проверяет наличие и актуальность ядра и Geo-баз, формируя текст статуса.
  Future<void> _checkComponentsStatus() async {
    final s = _settings;
    if (mounted) {
      setState(() {
        _status = s.tr(
          'Проверка компонентов...',
          'Checking components...',
          '正在检查组件...',
        );
      });
    }

    await widget.coreController.ensureCoreExists();
    final dir = await widget.coreController.getCurrentConfigDir();
    await widget.coreController.ensureGeoDatabase(dir, forceUpdate: false);

    final corePath = await widget.coreController.getAbsoluteCorePath();
    final geoPath = await widget.coreController.getAbsoluteGeoDbPath();
    final coreExists = await File(corePath).exists();
    final geoExists = await File(geoPath).exists();

    if (!coreExists || !geoExists) {
      if (mounted) {
        setState(() {
          _status = s.tr(
            'Компоненты отсутствуют. Обновите систему.',
            'Components missing. Please update.',
            '组件缺失，请更新。',
          );
        });
      }
      return;
    }

    // Реальная проверка свежести — само наличие файлов никогда не означает
    // «актуально». Сначала пытаемся честно сравнить с последними релизами в
    // сети; при недоступности сети откатываемся к локальным эвристикам
    // (встроенный ассет / возраст файлов), чтобы никогда ложно не заявить
    // «актуально».
    final String? latestCore = await _fetchLatestCoreVersion();
    final bool coreStale;
    if (latestCore != null &&
        latestCore.isNotEmpty &&
        _coreVersion.isNotEmpty) {
      coreStale = _compareVersions(_coreVersion, latestCore) < 0;
    } else {
      coreStale = await _isInstalledCoreStale();
    }

    final int geoAgeDays = await _oldestGeoDbAgeDays();
    const int geoStaleThresholdDays = 30;
    final bool geoStale;
    final DateTime? latestGeo = await _fetchLatestGeoPublishedAt();
    if (latestGeo != null) {
      final DateTime? oldestLocal = await _oldestGeoDbModified();
      // Допуск в 6 ч сглаживает ложные срабатывания из-за дрожания CDN/mtime.
      geoStale = oldestLocal == null ||
          latestGeo.isAfter(
            oldestLocal.toUtc().add(const Duration(hours: 6)),
          );
    } else {
      geoStale = geoAgeDays >= geoStaleThresholdDays;
    }

    final String coreVer = _coreVersion;
    final String coreVerPart = coreVer.isEmpty
        ? ''
        : ' ${s.tr('Ядро', 'Core', '核心')} ${coreVer.startsWith('v') ? coreVer : 'v$coreVer'}.';

    final String verdict;
    if (coreStale && geoStale) {
      verdict = s.tr(
        'Доступно обновление ядра и GeoIP-баз$coreVerPart Рекомендуется обновить компоненты.',
        'Core and GeoIP updates available$coreVerPart Consider updating components.',
        '有内核与 GeoIP 更新$coreVerPart 建议更新组件。',
      );
    } else if (coreStale) {
      verdict = s.tr(
        'Доступно обновление ядра Mihomo$coreVerPart Обновите ядро для актуальной защиты.',
        'Mihomo core update available$coreVerPart Update the core for current protection.',
        '有 Mihomo 内核更新$coreVerPart 建议更新内核以保持最新防护。',
      );
    } else if (geoStale) {
      verdict = s.tr(
        'GeoIP-базы устарели ($geoAgeDays дн.). Обновите базы маршрутизации.',
        'GeoIP databases are stale ($geoAgeDays d). Update the routing databases.',
        'GeoIP 数据库已过期（$geoAgeDays 天）。请更新路由数据库。',
      );
    } else {
      // Без точки в конце — AnimatedEllipsisText анимируется только когда текст
      // заканчивается точками, поэтому эта строка остаётся статичной.
      verdict = s.tr(
        'Все системные компоненты актуальны!',
        'All system components are up to date!',
        '所有系统组件均为最新！',
      );
    }

    if (mounted) {
      setState(() {
        _status = verdict;
      });
    }
  }

  /// Обновляет Geo-базы: при необходимости останавливает ядро, скачивает базы
  /// и заново запускает ядро, восстанавливая режим VPN.
  Future<void> _handleGeoUpdate() async {
    if (mounted) {
      setState(() {
        _isUpdatingGeo = true;
        _status = _settings.tr(
          'Обновление базы GeoIP...',
          'Updating GeoIP database...',
          '正在更新 GeoIP 数据库...',
        );
      });
    }

    final bool wasRunning = widget.coreController.isRunning.value;
    final bool wasConnected = widget.coreController.isVpnConnected.value;
    final String? activeConfig = widget.coreController.currentConfigPath;

    try {
      if (wasRunning) {
        if (mounted) {
          setState(() {
            _status = _settings.tr(
              'Остановка ядра для разблокировки файлов базы...',
              'Stopping core to unlock database files...',
              '正在停止核心以解锁数据库文件...',
            );
          });
        }
        await widget.coreController.stopCore();
        await Future.delayed(const Duration(milliseconds: 600));
      }

      final dir = await widget.coreController.getCurrentConfigDir();
      final success = await widget.coreController.ensureGeoDatabase(
        dir,
        forceUpdate: true,
      );

      if (wasRunning && activeConfig != null) {
        if (mounted) {
          setState(() {
            _status = _settings.tr(
              'Запуск сетевого ядра...',
              'Starting connection core...',
              '正在启动网络核心...',
            );
          });
        }
        await widget.coreController.startCore(activeConfig);
        if (wasConnected) {
          await widget.coreController.setVpnMode('Rule');
        }
      }

      if (mounted) {
        setState(() {
          _isUpdatingGeo = false;
          _status = success
              ? _settings.tr(
                  'Гео-база успешно обновлена!',
                  'Geo database successfully updated!',
                  'Geo 数据库更新成功！',
                )
              : _settings.tr(
                  'Не удалось загрузить базу GeoIP',
                  'Failed to download GeoIP database',
                  '下载 GeoIP 数据库失败',
                );
        });
      }
    } catch (e) {
      if (wasRunning && activeConfig != null) {
        try {
          await widget.coreController.startCore(activeConfig);
          if (wasConnected) {
            await widget.coreController.setVpnMode('Rule');
          }
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _isUpdatingGeo = false;
          _status = _settings.tr(
            'Ошибка обновления GeoIP: $e',
            'Error updating GeoIP: $e',
            '更新 GeoIP 出错：$e',
          );
        });
      }
    }
  }

  // ─── Построение интерфейса ───

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color accent = Theme.of(context).colorScheme.primary;

    return ValueListenableBuilder<String>(
      valueListenable: _settings.language,
      builder: (context, lang, child) {
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView(
            padding: const EdgeInsets.all(32.0),
            children: [
              Text(
                _settings.tr('Настройки системы', 'System Settings', '系统设置'),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w300,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
              ),
              const SizedBox(height: 24),
              _buildSectionTitle(
                _settings.tr('ОСНОВНОЕ', 'GENERAL', '常规'),
                isDark,
              ),
              _buildSettingCard(
                title: _settings.tr(
                  'Тема приложения',
                  'Application Theme',
                  '应用主题',
                ),
                subtitle: _settings.tr(
                  'Выберите системную, светлую или темную тему',
                  'Select system, light or dark mode',
                  '选择系统、浅色或深色模式',
                ),
                isDark: isDark,
                trailing: ValueListenableBuilder<ThemeMode>(
                  valueListenable: _settings.themeMode,
                  builder: (context, currentTheme, child) {
                    return SegmentedButton<ThemeMode>(
                      segments: [
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.system,
                          icon: const Icon(Icons.brightness_auto, size: 16),
                          label: Text(
                            _settings.tr('Система', 'System', '系统'),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.light,
                          icon: const Icon(Icons.light_mode, size: 16),
                          label: Text(
                            _settings.tr('Светлая', 'Light', '浅色'),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.dark,
                          icon: const Icon(Icons.dark_mode, size: 16),
                          label: Text(
                            _settings.tr('Темная', 'Dark', '深色'),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                      selected: {currentTheme},
                      onSelectionChanged: (Set<ThemeMode> newSelection) {
                        _settings.themeMode.value = newSelection.first;
                        _settings.saveSettings();
                      },
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        padding: WidgetStateProperty.all(
                          const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    );
                  },
                ),
              ),
              _buildSettingCard(
                title: _settings.tr('Цвет акцента', 'Accent color', '强调色'),
                subtitle: _settings.tr(
                  'Базовый цвет темы Material You',
                  'Base color for the Material You theme',
                  'Material You 主题的基础颜色',
                ),
                isDark: isDark,
                trailing: ValueListenableBuilder<int>(
                  valueListenable: _settings.seedColor,
                  builder: (context, currentSeed, child) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final value in _accentPresets)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: GestureDetector(
                              onTap: () {
                                _settings.seedColor.value = value;
                                _settings.saveSettings();
                              },
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: Color(value),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: value == currentSeed
                                        ? (isDark
                                            ? Colors.white
                                            : Colors.black87)
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Color(
                                        value,
                                      ).withValues(alpha: 0.4),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                                child: value == currentSeed
                                    ? const Icon(
                                        Icons.check,
                                        size: 13,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              _buildSettingCard(
                title: _settings.tr('Стиль темы', 'Theme style', '主题风格'),
                subtitle: _settings.tr(
                  'Вариант цветовой схемы Material You',
                  'Material You color scheme variant',
                  'Material You 配色方案变体',
                ),
                isDark: isDark,
                trailing: ValueListenableBuilder<String>(
                  valueListenable: _settings.themeVariant,
                  builder: (context, currentVariant, child) {
                    return PopupMenuButton<String>(
                      initialValue: currentVariant,
                      tooltip: _settings.tr(
                        'Выбрать стиль темы',
                        'Select theme style',
                        '选择主题风格',
                      ),
                      offset: const Offset(0, 36),
                      borderRadius: BorderRadius.circular(8),
                      color: isDark ? const Color(0xFF1E2227) : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      onSelected: (val) {
                        _settings.themeVariant.value = val;
                        _settings.saveSettings();
                      },
                      child: Container(
                        width: 145,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1E2227)
                              : const Color(0xFFF0F2F5),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.06),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                _variantLabel(currentVariant),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.arrow_drop_down,
                              size: 16,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ],
                        ),
                      ),
                      itemBuilder: (context) => kThemeVariants.keys.map((key) {
                        return PopupMenuItem<String>(
                          value: key,
                          child: Text(
                            _variantLabel(key),
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
              if (isDark)
                _buildSettingCard(
                  title: _settings.tr(
                    'Чисто чёрный (AMOLED)',
                    'Pure black (AMOLED)',
                    '纯黑 (AMOLED)',
                  ),
                  subtitle: _settings.tr(
                    'Истинно чёрный фон в тёмной теме',
                    'Use true black background in dark mode',
                    '深色模式下使用纯黑背景',
                  ),
                  isDark: isDark,
                  onTap: () {
                    _settings.pureBlack.value = !_settings.pureBlack.value;
                    _settings.saveSettings();
                  },
                  trailing: ValueListenableBuilder<bool>(
                    valueListenable: _settings.pureBlack,
                    builder: (context, pb, child) {
                      return Switch(
                        value: pb,
                        activeThumbColor: accent,
                        activeTrackColor: accent.withValues(alpha: 0.2),
                        inactiveThumbColor: Colors.grey,
                        inactiveTrackColor: Colors.transparent,
                        onChanged: (v) {
                          _settings.pureBlack.value = v;
                          _settings.saveSettings();
                        },
                      );
                    },
                  ),
                ),
              _buildSettingCard(
                title: _settings.tr('Язык', 'Language', '语言'),
                subtitle: _settings.tr(
                  'Сменить язык интерфейса',
                  'Change the interface language',
                  '更改界面语言',
                ),
                isDark: isDark,
                trailing: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment<String>(
                      value: 'ru',
                      label: Text('RU', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment<String>(
                      value: 'en',
                      label: Text('EN', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment<String>(
                      value: 'zh',
                      label: Text('中文', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  selected: {lang},
                  showSelectedIcon: false,
                  onSelectionChanged: (Set<String> newSelection) {
                    _settings.setLanguage(newSelection.first);
                  },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    padding: WidgetStateProperty.all(
                      const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
              ),
              _buildSettingCard(
                title: _settings.tr(
                  'Сворачивать в трей',
                  'Minimize to tray',
                  '最小化到托盘',
                ),
                subtitle: _settings.tr(
                  'При закрытии окна программа продолжит работу в фоне',
                  'App will continue running in background when closed',
                  '关闭窗口后程序将在后台继续运行',
                ),
                isDark: isDark,
                onTap: () {
                  setState(
                    () => _settings.minimizeToTray = !_settings.minimizeToTray,
                  );
                  _settings.saveSettings();
                },
                trailing: Switch(
                  value: _settings.minimizeToTray,
                  activeThumbColor: accent,
                  activeTrackColor: accent.withValues(alpha: 0.2),
                  inactiveThumbColor: Colors.grey,
                  inactiveTrackColor:
                      isDark ? Colors.transparent : Colors.black12,
                  onChanged: (v) {
                    setState(() => _settings.minimizeToTray = v);
                    _settings.saveSettings();
                  },
                ),
              ),
              _buildSettingCard(
                title: _settings.tr(
                  'Запускать при старте системы',
                  'Launch at startup',
                  '开机启动',
                ),
                subtitle: _settings.tr(
                  'Автоматический запуск JustClash при входе в Windows',
                  'Automatically start JustClash on Windows login',
                  '登录 Windows 时自动启动 JustClash',
                ),
                isDark: isDark,
                onTap: () {
                  final newVal = !_settings.launchAtStartup;
                  setState(() => _settings.launchAtStartup = newVal);
                  _settings.updateAutoStart(newVal);
                },
                trailing: Switch(
                  value: _settings.launchAtStartup,
                  activeThumbColor: accent,
                  activeTrackColor: accent.withValues(alpha: 0.2),
                  inactiveThumbColor: Colors.grey,
                  inactiveTrackColor:
                      isDark ? Colors.transparent : Colors.black12,
                  onChanged: (v) {
                    setState(() => _settings.launchAtStartup = v);
                    _settings.updateAutoStart(v);
                  },
                ),
              ),
              _buildSettingCard(
                title: _settings.tr(
                  'Авто-обновление подписки',
                  'Auto-update subscription',
                  '自动更新订阅',
                ),
                subtitle: _settings.tr(
                  'Периодическое обновление активного профиля',
                  'Update active profile periodically',
                  '定期更新当前配置',
                ),
                isDark: isDark,
                trailing: PopupMenuButton<int>(
                  initialValue: _settings.autoUpdateIntervalHours,
                  tooltip: _settings.tr(
                    'Выбрать интервал',
                    'Select interval',
                    '选择间隔',
                  ),
                  offset: const Offset(0, 36),
                  borderRadius: BorderRadius.circular(8),
                  color: isDark ? const Color(0xFF1E2227) : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  onSelected: (val) {
                    setState(() => _settings.autoUpdateIntervalHours = val);
                    _settings.saveSettings();
                  },
                  child: Container(
                    width: 145,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF1E2227)
                          : const Color(0xFFF0F2F5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.06),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Text(
                              _getAutoUpdateLabel(
                                _settings.autoUpdateIntervalHours,
                              ),
                              key: ValueKey(_settings.autoUpdateIntervalHours),
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? Colors.white : Colors.black87,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 16,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ],
                    ),
                  ),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 0,
                      child: Text(
                        _settings.tr('Отключено', 'Disabled', '已禁用'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    PopupMenuItem(
                      value: 1,
                      child: Text(
                        _settings.tr('Каждый час', 'Every 1 hour', '每 1 小时'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    PopupMenuItem(
                      value: 6,
                      child: Text(
                        _settings.tr(
                          'Каждые 6 часов',
                          'Every 6 hours',
                          '每 6 小时',
                        ),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    PopupMenuItem(
                      value: 12,
                      child: Text(
                        _settings.tr(
                          'Каждые 12 часов',
                          'Every 12 hours',
                          '每 12 小时',
                        ),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    PopupMenuItem(
                      value: 24,
                      child: Text(
                        _settings.tr('Раз в день', 'Daily', '每天'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<String>(
                valueListenable: widget.coreController.activeSourceType,
                builder: (context, sourceType, child) {
                  if (sourceType != 'raw') return const SizedBox.shrink();
                  return _buildSettingCard(
                    title: _settings.tr(
                      'Метод проверки пинга',
                      'Ping Method',
                      'Ping 方式',
                    ),
                    subtitle: _settings.tr(
                      'Измерение задержки через Core HTTP API или TCP',
                      'Measure latency via TCP or via Core HTTP API',
                      '通过 TCP 或核心 HTTP API 测量延迟',
                    ),
                    isDark: isDark,
                    trailing: PopupMenuButton<String>(
                      initialValue: _settings.pingMethod,
                      tooltip: _settings.tr(
                        'Выбрать метод проверки пинга',
                        'Select ping method',
                        '选择 Ping 方式',
                      ),
                      offset: const Offset(0, 36),
                      borderRadius: BorderRadius.circular(8),
                      color: isDark ? const Color(0xFF1E2227) : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      onSelected: (val) {
                        setState(() => _settings.pingMethod = val);
                        _settings.saveSettings();
                      },
                      child: Container(
                        width: 145,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1E2227)
                              : const Color(0xFFF0F2F5),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.06),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: Text(
                                  _getPingMethodLabel(_settings.pingMethod),
                                  key: ValueKey(_settings.pingMethod),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color:
                                        isDark ? Colors.white : Colors.black87,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                            Icon(
                              Icons.arrow_drop_down,
                              size: 16,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ],
                        ),
                      ),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'api',
                          child: Text(
                            'Core API (HTTP)',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'tcp',
                          child: Text('TCP', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              _buildSectionTitle(
                _settings.tr('КОМПОНЕНТЫ И ЯДРО', 'COMPONENTS & CORE', '组件与核心'),
                isDark,
              ),
              _buildSettingCard(
                title: _settings.tr(
                  'База данных маршрутов GeoIP',
                  'GeoIP routing database',
                  'GeoIP 路由数据库',
                ),
                subtitle: _settings.tr(
                  'GeoIP / GeoSite / GeoIP-Meta / ASN (MetaCubeX)',
                  'GeoIP / GeoSite / GeoIP-Meta / ASN (MetaCubeX)',
                  'GeoIP / GeoSite / GeoIP-Meta / ASN (MetaCubeX)',
                ),
                isDark: isDark,
                trailing: SizedBox(
                  width: 40,
                  height: 40,
                  child: _isUpdatingGeo
                      ? Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        )
                      : IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: _settings.tr(
                            'Обновить базу GeoIP',
                            'Update GeoIP database',
                            '更新 GeoIP 数据库',
                          ),
                          icon: Icon(
                            Icons.sync,
                            size: 18,
                            color: isDark ? Colors.grey : Colors.black54,
                          ),
                          onPressed: _handleGeoUpdate,
                        ),
                ),
              ),
              ValueListenableBuilder<GeoUpdateProgress?>(
                valueListenable: widget.coreController.geoProgress,
                builder: (context, progress, child) {
                  if (progress == null) return const SizedBox.shrink();
                  final bool known = progress.total > 0;
                  final double? ratio = known
                      ? (progress.received / progress.total).clamp(0.0, 1.0)
                      : null;
                  final String pct = known
                      ? '${((ratio ?? 0) * 100).toStringAsFixed(0)}%'
                      : _formatBytes(progress.received);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF111315) : Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accent.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: accent,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${_settings.tr('Загрузка', 'Downloading', '正在下载')} ${progress.fileName}  (${progress.fileIndex}/${progress.totalFiles})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                            ),
                            Text(
                              pct,
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 5,
                            backgroundColor:
                                isDark ? Colors.white10 : Colors.black12,
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              known
                                  ? '${_formatBytes(progress.received)} / ${_formatBytes(progress.total)}'
                                  : '${_formatBytes(progress.received)} ${_settings.tr('загружено', 'downloaded', '已下载')}',
                              style: TextStyle(
                                fontSize: 10,
                                color: isDark ? Colors.white38 : Colors.black38,
                                fontFamily: 'monospace',
                              ),
                            ),
                            Text(
                              '${_formatBytes(progress.speedBytesPerSec.round())}/s',
                              style: TextStyle(
                                fontSize: 10,
                                color: isDark ? Colors.white38 : Colors.black38,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
              _buildSettingCard(
                title: _settings.tr(
                  'Ядро Mihomo Core',
                  'Mihomo Core',
                  'Mihomo 核心',
                ),
                subtitle: _coreVersion.isNotEmpty
                    ? _settings.tr(
                        'Установленная версия: $_coreVersion',
                        'Installed version: $_coreVersion',
                        '已安装版本：$_coreVersion',
                      )
                    : _settings.tr(
                        'Mihomo (Clash.Meta) · Windows x64',
                        'Mihomo (Clash.Meta) · Windows x64',
                        'Mihomo (Clash.Meta) · Windows x64',
                      ),
                isDark: isDark,
                trailing: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Icon(
                      Icons.memory,
                      size: 18,
                      color: isDark ? Colors.grey : Colors.black54,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _buildSectionTitle(
                _settings.tr('УСТРОЙСТВО', 'DEVICE', '设备'),
                isDark,
              ),
              _buildSettingCard(
                title: 'HWID',
                subtitle: _deviceInfo?.hwid.isNotEmpty == true
                    ? _deviceInfo!.hwid
                    : _settings.tr('Определение...', 'Detecting...', '检测中...'),
                isDark: isDark,
                onTap: _copyHwid,
                trailing: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: _settings.tr(
                        'Копировать HWID',
                        'Copy HWID',
                        '复制 HWID',
                      ),
                      icon: Icon(
                        Icons.copy,
                        size: 18,
                        color: isDark ? Colors.grey : Colors.black54,
                      ),
                      onPressed: _copyHwid,
                    ),
                  ),
                ),
              ),
              _buildSettingCard(
                title: _settings.tr('Устройство', 'Device', '设备'),
                subtitle: _deviceSummary(),
                isDark: isDark,
                trailing: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Icon(
                      Icons.computer,
                      size: 18,
                      color: isDark ? Colors.grey : Colors.black54,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),
              if (_status.isNotEmpty)
                Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: AnimatedEllipsisText(
                      text: _status,
                      key: ValueKey(_status),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.black38,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Палитра предустановленных акцентных цветов (ARGB).
  static const List<int> _accentPresets = [
    0xFF2ECC71,
    0xFF03A9F4,
    0xFF665390,
    0xFF795548,
    0xFFE74C3C,
    0xFFFF9800,
    0xFFABD397,
    0xFFD8C0C3,
  ];

  /// Локализованная подпись варианта цветовой схемы Material You.
  String _variantLabel(String key) {
    switch (key) {
      case 'tonalSpot':
        return _settings.tr('Тональный', 'Tonal Spot', '色调');
      case 'fidelity':
        return _settings.tr('Точный', 'Fidelity', '保真');
      case 'monochrome':
        return _settings.tr('Монохром', 'Monochrome', '单色');
      case 'neutral':
        return _settings.tr('Нейтральный', 'Neutral', '中性');
      case 'vibrant':
        return _settings.tr('Яркий', 'Vibrant', '鲜艳');
      case 'expressive':
        return _settings.tr('Экспрессивный', 'Expressive', '表现力');
      case 'content':
        return _settings.tr('Контентный', 'Content', '内容');
      case 'rainbow':
        return _settings.tr('Радужный', 'Rainbow', '彩虹');
      case 'fruitSalad':
        return _settings.tr('Фруктовый', 'Fruit Salad', '缤纷');
      default:
        return key;
    }
  }

  // ─── Вспомогательные виджеты ───

  /// Заголовок секции настроек (мелкий капс с разрядкой).
  Widget _buildSectionTitle(String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 1.5,
          color: isDark ? Colors.white24 : Colors.black38,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// Карточка одной настройки: заголовок, подзаголовок и виджет справа.
  Widget _buildSettingCard({
    required String title,
    required String subtitle,
    required Widget trailing,
    required bool isDark,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF111315) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.02)
              : Colors.black.withValues(alpha: 0.05),
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white : Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.grey : Colors.black54,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
