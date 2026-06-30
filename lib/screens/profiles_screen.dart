// ═══════════════════════════════════════════════════════════════════════════
// ProfilesScreen — экран управления профилями (подписками).
//
// Назначение файла:
//   • Список локальных профилей (.yaml) и их метаданные (.json).
//   • Импорт по URL, синхронизация одного или всех профилей, удаление.
//   • Выбор активного профиля с горячей перезагрузкой конфига ядра.
//   • Отображение трафика/срока действия и индикаторы синхронизации.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/core_controller.dart';
import '../services/subscription_parser.dart';
import '../services/settings_service.dart';

/// Минимальное время показа анимации вращения/прогресса, даже если синхронизация
/// завершилась очень быстро — чтобы пользователь успел её заметить (тот же приём,
/// что и в proxies_screen._loadGroups).
const Duration _kMinSyncAnimDuration = Duration(milliseconds: 600);

/// Экран «Управление профилями»: импорт, синхронизация и выбор активной подписки.
class ProfilesScreen extends StatefulWidget {
  final CoreController coreController;
  const ProfilesScreen({super.key, required this.coreController});

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

/// Состояние экрана профилей: список файлов, метаданные и индикаторы синхронизации.
class _ProfilesScreenState extends State<ProfilesScreen> {
  // ─── Поля состояния ───

  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  List<File> _profileFiles = [];
  Map<String, Map<String, dynamic>> _profilesMeta = {};
  String _activeProfileFileName = '';
  bool _isUpdating = false;
  String? _syncingFileName;
  bool _syncingAll = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _scanProfiles();
    // Отражаем фоновые проходы «обновить всё» при холодном старте (запускаются
    // из main.dart) на этом экране, чтобы анимация синхронизации была видна
    // после полного перезапуска так же, как при ручном обновлении.
    widget.coreController.isRefreshingSubscriptions
        .addListener(_onExternalRefreshChanged);
    widget.coreController.refreshingProfileFile
        .addListener(_onExternalRefreshChanged);
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      // Не вызываем setState во время синхронизации: пустая перестройка здесь
      // пересоздала бы поддерево _RotatingSyncIcon (без стабильного ключа) и
      // перезапустила бы его AnimationController, из-за чего вращение мигало бы.
      // Вместо этого просто дожидаемся конца синхронизации; _scanProfiles
      // вызывается из самой синхронизации.
      if (!_isUpdating) {
        _scanProfiles();
      }
    });
  }

  /// Реагирует на внешнее (фоновое) обновление подписок: перестраивает экран
  /// и по завершении пересканирует профили.
  void _onExternalRefreshChanged() {
    if (!mounted) return;
    setState(() {});
    if (!widget.coreController.isRefreshingSubscriptions.value &&
        !_isUpdating) {
      // Внешнее обновление завершилось: пересканируем, чтобы список и подписи
      // «последнее обновление» отражали свежескачанные подписки.
      _scanProfiles();
    }
  }

  /// Показывает короткое уведомление (SnackBar) на 3 секунды.
  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    widget.coreController.isRefreshingSubscriptions
        .removeListener(_onExternalRefreshChanged);
    widget.coreController.refreshingProfileFile
        .removeListener(_onExternalRefreshChanged);
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  // ─── Сканирование профилей и метаданных ───

  /// Сканирует папку профилей: определяет активный профиль, собирает .yaml-файлы
  /// и их метаданные из .json-файлов.
  Future<void> _scanProfiles() async {
    try {
      final Directory docDir = await getApplicationDocumentsDirectory();
      final String targetPath = p.join(docDir.path, 'JustClash');

      final File activeMarker = File(p.join(targetPath, 'active_profile.txt'));
      if (await activeMarker.exists()) {
        _activeProfileFileName = (await activeMarker.readAsString()).trim();
      } else {
        _activeProfileFileName = 'config.yaml';
      }

      final Directory profilesDir = Directory(p.join(targetPath, 'profiles'));
      if (await profilesDir.exists()) {
        final List<FileSystemEntity> entities =
            await profilesDir.list().toList();
        final List<File> files = entities
            .whereType<File>()
            .where((f) => f.path.endsWith('.yaml'))
            .toList();

        final Map<String, Map<String, dynamic>> tempMeta = {};
        for (final file in files) {
          final String fileName = p.basename(file.path);
          final String metaPath = file.path.endsWith('.yaml')
              ? '${file.path.substring(0, file.path.length - 5)}.json'
              : file.path.replaceAll('.yaml', '.json');
          final File metaFile = File(metaPath);
          if (await metaFile.exists()) {
            try {
              final content = await metaFile.readAsString();
              final decoded = jsonDecode(content);
              if (decoded is Map) {
                tempMeta[fileName] = decoded.map(
                  (k, v) => MapEntry(k.toString(), v),
                );
              }
            } catch (_) {}
          }
        }

        if (mounted) {
          setState(() {
            _profileFiles = files;
            _profilesMeta = tempMeta;
          });
        }
      }
    } catch (e) {
      debugPrint('Ошибка сканирования локальных профилей: $e');
    }
  }

  /// Проверяет, является ли имя зарезервированным в Windows (CON, PRN, COM1 и т.д.).
  bool _isWindowsReservedName(String name) {
    const reserved = {
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
    };
    return reserved.contains(name.toUpperCase());
  }

  // ─── Загрузка и синхронизация подписок ───

  /// Загружает новую подписку по URL: проверяет имя, скачивает, сохраняет
  /// метаданные и делает профиль активным.
  Future<void> _downloadNewProfile() async {
    final String url = _urlController.text.trim();
    final String name = _nameController.text.trim();
    final s = SettingsService();

    if (url.isEmpty || name.isEmpty) {
      _notify(
        s.tr(
          'Ошибка: Заполните все поля ввода!',
          'Error: Fill in all fields!',
          '错误：请填写所有输入字段！',
        ),
      );
      return;
    }

    final String validationCheck =
        name.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '').trim();
    if (validationCheck.isEmpty) {
      _notify(
        s.tr(
          'Ошибка: Недопустимые символы в названии!',
          'Error: Invalid characters in name!',
          '错误：名称包含无效字符！',
        ),
      );
      return;
    }

    if (validationCheck.length > 50) {
      _notify(
        s.tr(
          'Ошибка: Слишком длинное имя (максимум 50 символов)!',
          'Error: Name is too long (max 50 chars)!',
          '错误：名称过长（最多 50 个字符）！',
        ),
      );
      return;
    }

    if (_isWindowsReservedName(validationCheck)) {
      _notify(
        s.tr(
          'Ошибка: Имя "$validationCheck" зарезервировано системой!',
          'Error: Name "$validationCheck" is reserved by the system!',
          '错误：名称 "$validationCheck" 已被系统保留！',
        ),
      );
      return;
    }

    setState(() {
      _isUpdating = true;
    });

    try {
      final parser = SubscriptionParser();
      await parser.fetchAndSaveSubscription(url, validationCheck);

      final Directory docDir = await getApplicationDocumentsDirectory();
      final String metaPath = p.join(
        docDir.path,
        'JustClash',
        'profiles',
        '$validationCheck.json',
      );
      final File metaFile = File(metaPath);
      Map<String, dynamic> currentMeta = {};
      if (await metaFile.exists()) {
        try {
          currentMeta = jsonDecode(await metaFile.readAsString());
        } catch (_) {}
      }
      currentMeta['subscription_url'] = url;
      currentMeta['last_update'] = DateTime.now().millisecondsSinceEpoch;
      await metaFile.writeAsString(jsonEncode(currentMeta), flush: true);

      if (!mounted) return;
      _urlController.clear();
      _nameController.clear();

      await _scanProfiles();
      await _selectActiveProfile('$validationCheck.yaml');

      if (mounted && currentMeta['source_type'] == 'raw') {
        final int skipped =
            (currentMeta['skipped_nodes'] as num?)?.toInt() ?? 0;
        final int totalNodes =
            (currentMeta['total_nodes'] as num?)?.toInt() ?? 0;
        await _showRawImportWarning(skipped, totalNodes);
      }
    } catch (e) {
      _notify(
        s.tr(
          'Не удалось загрузить подписку: $e',
          'Failed to load subscription: $e',
          '加载订阅失败：$e',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  /// Синхронизирует один профиль по сохранённому URL подписки.
  Future<void> _syncProfile(String fileName, String? storedUrl) async {
    final s = SettingsService();

    if (storedUrl == null || storedUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            s.tr(
              'Для этого профиля отсутствует сохраненный URL',
              'No saved URL for this profile',
              '此配置没有保存的 URL',
            ),
          ),
        ),
      );
      return;
    }

    final Stopwatch sw = Stopwatch()..start();
    setState(() {
      _isUpdating = true;
      _syncingFileName = fileName;
      _syncingAll = false;
    });

    try {
      final String shortName = fileName.replaceAll('.yaml', '');
      final parser = SubscriptionParser();
      await parser.fetchAndSaveSubscription(storedUrl, shortName);

      final Directory docDir = await getApplicationDocumentsDirectory();
      final String metaPath = p.join(
        docDir.path,
        'JustClash',
        'profiles',
        '$shortName.json',
      );
      final File metaFile = File(metaPath);
      Map<String, dynamic> currentMeta = {};
      if (await metaFile.exists()) {
        try {
          currentMeta = jsonDecode(await metaFile.readAsString());
        } catch (_) {}
      }
      currentMeta['subscription_url'] = storedUrl;
      currentMeta['last_update'] = DateTime.now().millisecondsSinceEpoch;
      await metaFile.writeAsString(jsonEncode(currentMeta), flush: true);

      if (!mounted) return;
      await _scanProfiles();
      if (!mounted) return;
      if (_activeProfileFileName == fileName) {
        await _selectActiveProfile(fileName);
      }
    } catch (e) {
      _notify(s.tr('Сбой синхронизации: $e', 'Sync failed: $e', '同步失败：$e'));
    } finally {
      // Держим вращение/прогресс минимальное время, чтобы быструю загрузку
      // пользователь всё же заметил (как в proxies_screen._loadGroups).
      final Duration elapsed = sw.elapsed;
      if (elapsed < _kMinSyncAnimDuration) {
        await Future.delayed(_kMinSyncAnimDuration - elapsed);
      }
      if (mounted) {
        setState(() {
          _isUpdating = false;
          _syncingFileName = null;
          _syncingAll = false;
        });
      }
    }
  }

  /// Обновляет все профили с сохранённым URL подписки, переиспользуя ту же
  /// анимацию/прогресс, что и одиночная синхронизация. Ошибки собираются и
  /// сообщаются в конце; одна «мёртвая» подписка не прерывает остальные.
  Future<void> _syncAllProfiles() async {
    final s = SettingsService();
    if (_isUpdating) return;

    final List<(String, String)> queue = [];
    for (final file in _profileFiles) {
      final String fileName = p.basename(file.path);
      final String? url =
          _profilesMeta[fileName]?['subscription_url']?.toString();
      if (url != null && url.isNotEmpty) {
        queue.add((fileName, url));
      }
    }

    if (queue.isEmpty) {
      _notify(
        s.tr(
          'Нет профилей с сохранённым URL для обновления',
          'No profiles with a saved URL to update',
          '没有可更新的已保存 URL 配置',
        ),
      );
      return;
    }

    final Stopwatch sw = Stopwatch()..start();
    setState(() {
      _isUpdating = true;
      _syncingAll = true;
      _syncingFileName = null;
    });

    int failures = 0;
    try {
      final Directory docDir = await getApplicationDocumentsDirectory();
      final Directory profilesDir =
          Directory(p.join(docDir.path, 'JustClash', 'profiles'));
      for (final (fileName, url) in queue) {
        if (!mounted) return;
        setState(() {
          _syncingFileName = fileName;
        });
        try {
          final String shortName = fileName.replaceAll('.yaml', '');
          await SubscriptionParser().fetchAndSaveSubscription(url, shortName);
          final File metaFile =
              File(p.join(profilesDir.path, '$shortName.json'));
          Map<String, dynamic> currentMeta = {};
          if (await metaFile.exists()) {
            try {
              currentMeta = jsonDecode(await metaFile.readAsString());
            } catch (_) {}
          }
          currentMeta['subscription_url'] = url;
          currentMeta['last_update'] = DateTime.now().millisecondsSinceEpoch;
          await metaFile.writeAsString(jsonEncode(currentMeta), flush: true);
        } catch (e) {
          failures++;
          debugPrint('Синхронизация всех: сбой $fileName: $e');
        }
        try {
          if (!mounted) continue;
          final String targetPath = p.join(profilesDir.path, fileName);
          final String activePath =
              widget.coreController.currentConfigPath ?? '';
          if (widget.coreController.isRunning.value &&
              activePath.toLowerCase() == targetPath.toLowerCase()) {
            await widget.coreController.hotReloadConfig(targetPath);
          }
        } catch (e) {
          debugPrint('Синхронизация всех: сбой hot-reload $fileName: $e');
        }
      }

      if (mounted) await _scanProfiles();
      if (mounted) {
        if (failures == 0) {
          _notify(
            s.tr(
              'Все профили обновлены',
              'All profiles updated',
              '所有配置已更新',
            ),
          );
        } else {
          _notify(
            s.tr(
              'Обновлено с ошибками: $failures из ${queue.length}',
              'Updated with errors: $failures of ${queue.length}',
              '更新出错：$failures / ${queue.length}',
            ),
          );
        }
      }
    } finally {
      final Duration elapsed = sw.elapsed;
      if (elapsed < _kMinSyncAnimDuration) {
        await Future.delayed(_kMinSyncAnimDuration - elapsed);
      }
      if (mounted) {
        setState(() {
          _isUpdating = false;
          _syncingAll = false;
          _syncingFileName = null;
        });
      }
    }
  }

  // ─── Выбор, диалоги и удаление профиля ───

  /// Показывает предупреждение об импорте сырого списка узлов (без правил
  /// маршрутизации провайдера) и о числе пропущенных узлов.
  Future<void> _showRawImportWarning(int skipped, int totalNodes) async {
    if (!mounted) return;
    final s = SettingsService();
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF15181B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        title: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 18,
              color: isDark ? Colors.amberAccent : Colors.orange,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                s.tr(
                  'Импортировано как список узлов',
                  'Imported as a raw node list',
                  '已作为原始节点列表导入',
                ),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.tr(
                  'Это не Clash/Mihomo-конфиг: правил маршрутизации провайдера нет. Весь трафик идёт через прокси (напрямую — только LAN). Маршрутизация по странам недоступна.',
                  'This is not a Clash/Mihomo config: there are no provider routing rules. All traffic goes through the proxy (only LAN is direct). Per-country routing is unavailable.',
                  '这不是 Clash/Mihomo 配置：没有提供商路由规则。所有流量都通过代理（仅局域网直连）。无法按国家/地区路由。',
                ),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
              if (skipped > 0) ...[
                const SizedBox(height: 10),
                Text(
                  s.tr(
                    'Импортировано узлов: ${totalNodes - skipped} из $totalNodes (пропущено $skipped).',
                    'Imported nodes: ${totalNodes - skipped} of $totalNodes (skipped $skipped).',
                    '已导入节点：${totalNodes - skipped}/$totalNodes（跳过 $skipped）。',
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.amberAccent : Colors.orange,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.tr('Понятно', 'Got it', '知道了')),
          ),
        ],
      ),
    );
  }

  /// Делает профиль активным: записывает маркер и горячо перезагружает конфиг ядра.
  Future<void> _selectActiveProfile(String fileName) async {
    try {
      final Directory docDir = await getApplicationDocumentsDirectory();
      final File activeMarker = File(
        p.join(docDir.path, 'JustClash', 'active_profile.txt'),
      );
      await activeMarker.writeAsString(fileName, flush: true);

      if (!mounted) return;
      setState(() {
        _activeProfileFileName = fileName;
      });

      final String fullPath = p.join(
        docDir.path,
        'JustClash',
        'profiles',
        fileName,
      );
      final bool isSuccess = await widget.coreController.hotReloadConfig(
        fullPath,
      );

      if (!isSuccess && mounted) {
        final s = SettingsService();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              s.tr(
                'Внимание: не удалось применить конфигурацию ядра.',
                'Warning: failed to apply core configuration.',
                '警告：应用核心配置失败。',
              ),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (_) {}
  }

  /// Удаляет профиль и его метаданные; если он был активным — останавливает ядро.
  Future<void> _deleteProfile(File file, String fileName) async {
    try {
      if (await file.exists()) await file.delete();

      final String metaPath = file.path.endsWith('.yaml')
          ? '${file.path.substring(0, file.path.length - 5)}.json'
          : file.path.replaceAll('.yaml', '.json');
      final File metaFile = File(metaPath);

      if (await metaFile.exists()) await metaFile.delete();

      if (!mounted) return;
      if (_activeProfileFileName == fileName) {
        setState(() {
          _activeProfileFileName = '';
        });
        final Directory docDir = await getApplicationDocumentsDirectory();
        final File activeMarker = File(
          p.join(docDir.path, 'JustClash', 'active_profile.txt'),
        );
        if (await activeMarker.exists()) await activeMarker.delete();

        await widget.coreController.stopCore();
      }
      if (!mounted) return;
      await _scanProfiles();
    } catch (_) {}
  }

  // ─── Форматирование ───

  /// Форматирует число байт в читаемую строку (B/KB/MB/GB/TB).
  String _formatBytes(num? bytes) {
    if (bytes == null) return '0 B';
    final double b = bytes.toDouble();
    if (b <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double val = b;
    while (val >= 1024 && i < suffixes.length - 1) {
      val /= 1024;
      i++;
    }
    return '${val.toStringAsFixed(1)} ${suffixes[i]}';
  }

  /// Форматирует дату окончания подписки в ДД.ММ.ГГГГ; «Бессрочно» при отсутствии.
  String _formatExpiry(dynamic expire) {
    final s = SettingsService();
    if (expire == null) return s.tr('Бессрочно', 'Unlimited', '无限制');

    final double expDouble = (expire is num)
        ? expire.toDouble()
        : (double.tryParse(expire.toString()) ?? 0.0);

    if (!expDouble.isFinite || expDouble <= 0) {
      return s.tr('Бессрочно', 'Unlimited', '无限制');
    }

    final int exp = expDouble.toInt();
    int ms = exp;
    if (exp < 100000000000) {
      ms = exp * 1000;
    }

    if (ms.abs() > 8640000000000000) {
      return s.tr('Бессрочно', 'Unlimited', '无限制');
    }

    try {
      final DateTime date = DateTime.fromMillisecondsSinceEpoch(ms);
      final day = date.day.toString().padLeft(2, '0');
      final month = date.month.toString().padLeft(2, '0');
      return '$day.$month.${date.year}';
    } catch (_) {
      return s.tr('Бессрочно', 'Unlimited', '无限制');
    }
  }

  /// Открывает диалог добавления нового профиля (имя + ссылка подписки).
  Future<void> _openAddProfileDialog() async {
    final s = SettingsService();
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        void submit() {
          Navigator.of(ctx).pop();
          _downloadNewProfile();
        }

        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF15181B) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            s.tr('Новый профиль', 'New profile', '新配置'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _nameController,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => FocusScope.of(ctx).nextFocus(),
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  decoration: InputDecoration(
                    hintText: s.tr(
                      'Название (например, MyServer)',
                      'Name (e.g., MyServer)',
                      '名称（例如 MyServer）',
                    ),
                    hintStyle: TextStyle(
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => submit(),
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  decoration: InputDecoration(
                    hintText: s.tr(
                      'Ссылка подписки или Clash Link',
                      'Subscription URL or Clash Link',
                      '订阅链接或 Clash Link',
                    ),
                    hintStyle: TextStyle(
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(s.tr('Отмена', 'Cancel', '取消')),
            ),
            FilledButton(
              onPressed: submit,
              child: Text(s.tr('Добавить', 'Add', '添加')),
            ),
          ],
        );
      },
    );
  }

  /// Возвращает относительную подпись времени последнего обновления подписки.
  String _formatLastUpdate(dynamic ts) {
    final s = SettingsService();
    if (ts == null) return s.tr('Не обновлялось', 'Never updated', '从未更新');
    final int ms =
        (ts is num) ? ts.toInt() : (int.tryParse(ts.toString()) ?? 0);
    if (ms <= 0) return s.tr('Не обновлялось', 'Never updated', '从未更新');
    final DateTime dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final Duration diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) {
      return s.tr('Обновлено только что', 'Updated just now', '刚刚更新');
    }
    if (diff.inMinutes < 60) {
      return s.tr(
        'Обновлено ${diff.inMinutes} мин. назад',
        'Updated ${diff.inMinutes} min ago',
        '${diff.inMinutes} 分钟前更新',
      );
    }
    if (diff.inHours < 24) {
      return s.tr(
        'Обновлено ${diff.inHours} ч. назад',
        'Updated ${diff.inHours} h ago',
        '${diff.inHours} 小时前更新',
      );
    }
    return s.tr(
      'Обновлено ${diff.inDays} дн. назад',
      'Updated ${diff.inDays} d ago',
      '${diff.inDays} 天前更新',
    );
  }

  // ─── Построение интерфейса ───

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ValueListenableBuilder<String>(
      valueListenable: SettingsService().language,
      builder: (context, lang, child) {
        final s = SettingsService();
        final bool extRefreshing =
            widget.coreController.isRefreshingSubscriptions.value;
        final String? extProfile =
            widget.coreController.refreshingProfileFile.value;
        return Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          s.tr(
                            'Управление профилями',
                            'Profile Management',
                            '配置管理',
                          ),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                        ),
                        IconButton(
                          tooltip: s.tr(
                            'Обновить все подписки',
                            'Refresh all subscriptions',
                            '刷新全部订阅',
                          ),
                          onPressed: (_isUpdating || extRefreshing)
                              ? null
                              : _syncAllProfiles,
                          icon: (_syncingAll || extRefreshing)
                              ? _RotatingSyncIcon(
                                  key: const ValueKey('sync-all-spin'),
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : Icon(
                                  Icons.sync,
                                  size: 20,
                                  color:
                                      isDark ? Colors.white54 : Colors.black54,
                                ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: _profileFiles.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.folder_open,
                                    size: 40,
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.15)
                                        : Colors.black12,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    s.tr(
                                      'Нет активных профилей',
                                      'No active profiles',
                                      '没有可用配置',
                                    ),
                                    style: TextStyle(
                                      color: isDark
                                          ? Colors.white38
                                          : Colors.black54,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    s.tr(
                                      'Нажмите «Добавить», чтобы импортировать',
                                      'Tap «Add» to import',
                                      '点击“添加”以导入',
                                    ),
                                    style: TextStyle(
                                      color: isDark
                                          ? Colors.white24
                                          : Colors.black38,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: _profileFiles.length,
                              itemBuilder: (context, index) {
                                final Color accent = Theme.of(
                                  context,
                                ).colorScheme.primary;
                                final File file = _profileFiles[index];
                                final String fileName = p.basename(file.path);
                                final bool isActive =
                                    fileName == _activeProfileFileName;
                                final meta = _profilesMeta[fileName];

                                final String profileDisplayName =
                                    fileName.replaceAll('.yaml', '');

                                int upload = 0;
                                int download = 0;
                                int total = 0;
                                dynamic expire;
                                String? storedUrl;
                                dynamic lastUpdateTs;

                                bool hasStats = false;
                                bool isUnlimited = false;

                                if (meta != null) {
                                  upload =
                                      (meta['upload'] as num?)?.toInt() ?? 0;
                                  download =
                                      (meta['download'] as num?)?.toInt() ?? 0;
                                  total = (meta['total'] as num?)?.toInt() ?? 0;
                                  expire = meta['expire'];
                                  storedUrl =
                                      meta['subscription_url']?.toString();
                                  lastUpdateTs = meta['last_update'];

                                  if (total > 0 ||
                                      upload > 0 ||
                                      download > 0 ||
                                      (expire != null && expire != 0)) {
                                    hasStats = true;
                                  }

                                  if (hasStats && total == 0) {
                                    isUnlimited = true;
                                  }
                                }

                                final int used = upload + download;
                                double progress = 0.0;

                                if (isUnlimited) {
                                  progress = 1.0;
                                } else if (total > 0) {
                                  progress = (used / total).clamp(0.0, 1.0);
                                }

                                Color progressColor = const Color(0xFF2ECC71);
                                if (!isUnlimited) {
                                  if (progress > 0.8) {
                                    progressColor = Colors.orangeAccent;
                                  }
                                  if (progress > 0.95) {
                                    progressColor = Colors.redAccent;
                                  }
                                }

                                return GestureDetector(
                                  onTap: () => _selectActiveProfile(fileName),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: isActive
                                          ? (isDark
                                              ? const Color(0xFF161A1E)
                                              : accent.withValues(
                                                  alpha: 0.06,
                                                ))
                                          : (isDark
                                              ? const Color(
                                                  0xFF111315,
                                                ).withValues(alpha: 0.6)
                                              : Colors.white),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: isActive
                                            ? (isDark
                                                ? accent.withValues(
                                                    alpha: 0.3,
                                                  )
                                                : accent.withValues(
                                                    alpha: 0.5,
                                                  ))
                                            : (isDark
                                                ? Colors.white.withValues(
                                                    alpha: 0.04,
                                                  )
                                                : Colors.black.withValues(
                                                    alpha: 0.05,
                                                  )),
                                        width: isActive && !isDark ? 1.5 : 1,
                                      ),
                                      boxShadow: isDark
                                          ? []
                                          : [
                                              BoxShadow(
                                                color: isActive
                                                    ? accent.withValues(
                                                        alpha: 0.05,
                                                      )
                                                    : Colors.black.withValues(
                                                        alpha: 0.02,
                                                      ),
                                                blurRadius: isActive ? 10 : 5,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    isActive
                                                        ? Icons.check_circle
                                                        : Icons
                                                            .radio_button_off,
                                                    color: isActive
                                                        ? accent
                                                        : (isDark
                                                            ? Colors.white24
                                                            : Colors.black26),
                                                    size: 16,
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Text(
                                                      profileDisplayName,
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        fontWeight: isActive
                                                            ? FontWeight.w600
                                                            : FontWeight.w400,
                                                        color: isActive
                                                            ? (isDark
                                                                ? Colors.white
                                                                : Colors
                                                                    .black87)
                                                            : (isDark
                                                                ? Colors.white70
                                                                : Colors
                                                                    .black87),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Row(
                                              children: [
                                                if (storedUrl != null &&
                                                    storedUrl.isNotEmpty)
                                                  IconButton(
                                                    icon: (_syncingFileName ==
                                                                fileName ||
                                                            extProfile ==
                                                                fileName)
                                                        ? _RotatingSyncIcon(
                                                            key: ValueKey(
                                                                'sync-spin-$fileName'),
                                                            size: 16,
                                                            color: accent,
                                                          )
                                                        : Icon(
                                                            Icons.sync,
                                                            size: 16,
                                                            color: isDark
                                                                ? Colors.white54
                                                                : Colors
                                                                    .black54,
                                                          ),
                                                    padding: EdgeInsets.zero,
                                                    constraints:
                                                        const BoxConstraints(),
                                                    onPressed: (_isUpdating ||
                                                            extRefreshing)
                                                        ? null
                                                        : () => _syncProfile(
                                                              fileName,
                                                              storedUrl,
                                                            ),
                                                    tooltip: s.tr(
                                                      'Синхронизировать подписку',
                                                      'Sync subscription',
                                                      '同步订阅',
                                                    ),
                                                  ),
                                                const SizedBox(width: 12),
                                                IconButton(
                                                  icon: const Icon(
                                                    Icons.delete_outline,
                                                    size: 16,
                                                    color: Colors.redAccent,
                                                  ),
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(),
                                                  onPressed: () =>
                                                      _deleteProfile(
                                                    file,
                                                    fileName,
                                                  ),
                                                  tooltip: s.tr(
                                                    'Удалить профиль',
                                                    'Delete profile',
                                                    '删除配置',
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        if (meta != null) ...[
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.history,
                                                size: 11,
                                                color: isDark
                                                    ? Colors.white38
                                                    : Colors.black38,
                                              ),
                                              const SizedBox(width: 5),
                                              Text(
                                                _formatLastUpdate(lastUpdateTs),
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: isDark
                                                      ? Colors.white38
                                                      : Colors.black38,
                                                  fontWeight: FontWeight.w400,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                        if (hasStats) ...[
                                          const SizedBox(height: 12),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                isUnlimited
                                                    ? s.tr(
                                                        'Использовано: ${_formatBytes(used)} / Безлимит',
                                                        'Used: ${_formatBytes(used)} / Unlimited',
                                                        '已用：${_formatBytes(used)} / 无限制',
                                                      )
                                                    : s.tr(
                                                        'Использовано: ${_formatBytes(used)} / ${_formatBytes(total)}',
                                                        'Used: ${_formatBytes(used)} / ${_formatBytes(total)}',
                                                        '已用：${_formatBytes(used)} / ${_formatBytes(total)}',
                                                      ),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: isDark
                                                      ? Colors.white54
                                                      : Colors.black54,
                                                ),
                                              ),
                                              Text(
                                                s.tr(
                                                  'Истекает: ${_formatExpiry(expire)}',
                                                  'Expires: ${_formatExpiry(expire)}',
                                                  '到期：${_formatExpiry(expire)}',
                                                ),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: isDark
                                                      ? Colors.white54
                                                      : Colors.black54,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            child: LinearProgressIndicator(
                                              value: progress,
                                              backgroundColor: isDark
                                                  ? Colors.white.withValues(
                                                      alpha: 0.05,
                                                    )
                                                  : Colors.black12,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                progressColor,
                                              ),
                                              minHeight: 4,
                                            ),
                                          ),
                                        ] else if (meta != null) ...[
                                          const SizedBox(height: 8),
                                          Text(
                                            s.tr(
                                              'Провайдер не передает статистику',
                                              'Provider does not supply statistics',
                                              '提供商不提供统计信息',
                                            ),
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: isDark
                                                  ? Colors.white30
                                                  : Colors.black38,
                                              fontWeight: FontWeight.w400,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: (_isUpdating || extRefreshing)
                    ? const LinearProgressIndicator(
                        minHeight: 3,
                        key: ValueKey('updating'),
                      )
                    : const SizedBox(
                        height: 3,
                        key: ValueKey('idle'),
                      ),
              ),
            ),
            Positioned(
              right: 24,
              bottom: 24,
              child: FloatingActionButton.extended(
                onPressed: (_isUpdating || extRefreshing)
                    ? null
                    : _openAddProfileDialog,
                icon: const Icon(Icons.add),
                label: Text(SettingsService().tr('Добавить', 'Add', '添加')),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Вращающаяся иконка синхронизации (бесконечное вращение, период 900 мс).
class _RotatingSyncIcon extends StatefulWidget {
  final Color color;
  final double size;
  const _RotatingSyncIcon({super.key, required this.color, required this.size});

  @override
  State<_RotatingSyncIcon> createState() => _RotatingSyncIconState();
}

class _RotatingSyncIconState extends State<_RotatingSyncIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(Icons.sync, size: widget.size, color: widget.color),
    );
  }
}
