import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// ═══════════════════════════════════════════════════════════════════════════
//  SettingsService
//  Хранение и сохранение настроек приложения (синглтон).
//
//  Настройки хранятся в settings.json в папке документов пользователя.
//  Запись атомарная (через .tmp и .bak) и сериализованная (очередь),
//  чтобы параллельные вызовы не повредили файл. Реактивные поля (ValueNotifier)
//  позволяют UI обновляться при изменении темы, языка и прочих параметров.
// ═══════════════════════════════════════════════════════════════════════════

/// Сервис настроек приложения (единый экземпляр на всё приложение).
class SettingsService {
  // ─── Синглтон ───
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  // ─── Сохраняемые простые настройки ───

  /// Сворачивать в трей вместо закрытия.
  bool minimizeToTray = true;

  /// Запускать приложение при входе в систему (автозапуск).
  bool launchAtStartup = false;

  /// Признак первого запуска (для приветственных экранов и т.п.).
  bool isFirstLaunch = true;

  /// Интервал автообновления подписки в часах (0 — выключено).
  int autoUpdateIntervalHours = 0;

  /// Имя последнего выбранного узла (глобально).
  String lastSelectedProxy = '';

  /// Способ измерения пинга: 'api' (через ядро) или иной метод.
  String pingMethod = 'api';

  /// Случайный секрет (уникальный для установки) для локального REST API
  /// Mihomo (external-controller). Записывается в каждый сгенерированный
  /// конфиг и отправляется как Bearer-токен в каждом запросе к API, чтобы
  /// другие локальные процессы не могли управлять прокси или читать данные
  /// узлов. Генерируется один раз при первом запуске.
  String apiSecret = '';

  /// Сгенерировать случайный 128-битный секрет (32 hex-символа) на криптостойком ГПСЧ.
  String _generateSecret() {
    final Random rng = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ─── Выбор узла по группам ───

  /// Выбор узла для каждой группы. Ключ = "<профиль>\u0001<группа>" → имя узла.
  /// Позволяет восстановить выбранный узел в КАЖДОЙ группе-селекторе
  /// (мультигрупповой Remnawave), а не только одно глобальное значение.
  final Map<String, String> groupSelections = <String, String>{};

  // ─── Реактивные настройки UI (ValueNotifier) ───

  /// Режим темы: системная / светлая / тёмная.
  final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );

  /// Язык интерфейса (ru/en/zh).
  final ValueNotifier<String> language = ValueNotifier<String>('en');

  /// Скрывать (размывать) IP-адрес в интерфейсе.
  final ValueNotifier<bool> blurIp = ValueNotifier<bool>(false);

  /// Seed-цвет для генерации палитры Material 3.
  final ValueNotifier<int> seedColor = ValueNotifier<int>(0xFF03A9F4);

  /// Вариант динамической схемы (см. kThemeVariants).
  final ValueNotifier<String> themeVariant = ValueNotifier<String>('tonalSpot');

  /// Режим чистого чёрного (OLED).
  final ValueNotifier<bool> pureBlack = ValueNotifier<bool>(false);

  /// Режим отображения списка прокси: 'grid' или 'list'.
  final ValueNotifier<String> proxyViewMode = ValueNotifier<String>('grid');

  // ─── Путь к файлу настроек ───

  /// Кэш вычисленного пути к settings.json.
  String? _cachedPath;

  /// Путь к файлу настроек (вычисляется один раз и кэшируется).
  Future<String> get _path async {
    if (_cachedPath != null) return _cachedPath!;
    final directory = await getApplicationDocumentsDirectory();
    _cachedPath = p.join(directory.path, 'JustClash', 'settings.json');
    return _cachedPath!;
  }

  // ─── Язык и режим отображения ───

  /// Поддерживаемые языки интерфейса.
  static const List<String> supportedLanguages = ['ru', 'en', 'zh'];

  /// Установить язык (неизвестный код → 'en') и сохранить.
  void setLanguage(String code) {
    final String normalized = supportedLanguages.contains(code) ? code : 'en';
    language.value = normalized;
    saveSettings();
  }

  /// Установить режим отображения списка прокси (grid/list) и сохранить.
  void setProxyViewMode(String mode) {
    proxyViewMode.value = mode == 'list' ? 'list' : 'grid';
    saveSettings();
  }

  /// Ключ хранения выбора: "<профиль>\u0001<группа>" (разделитель — управляющий символ 0x01).
  String _selectionKey(String profile, String group) => '$profile\u0001$group';

  /// Получить сохранённый выбор узла для пары профиль+группа.
  String? getGroupSelection(String profile, String group) =>
      groupSelections[_selectionKey(profile, group)];

  /// Запомнить выбор узла для пары профиль+группа (только в памяти;
  /// сохранение настроек — на стороне вызывающего кода).
  void setGroupSelection(String profile, String group, String node) {
    if (profile.isEmpty || group.isEmpty || node.isEmpty) return;
    groupSelections[_selectionKey(profile, group)] = node;
  }

  // ─── Локализация строк ───

  /// Выбрать строку по текущему языку (ru/en/zh).
  String tr(String ru, String en, String zh) {
    switch (language.value) {
      case 'ru':
        return ru;
      case 'zh':
        return zh;
      default:
        return en;
    }
  }

  // ─── Загрузка и сохранение ───

  /// Загрузить настройки из settings.json (с откатом на резервную копию .bak).
  Future<void> loadSettings() async {
    try {
      final file = File(await _path);
      final backupFile = File('${file.path}.bak');
      String content = '';
      if (await file.exists()) {
        content = await file.readAsString();
      }
      // Откат на резервную копию атомарной записи, если основной файл отсутствует
      // или пуст (например, сбой в коротком окне между этапами переименования).
      if (content.trim().isEmpty && await backupFile.exists()) {
        content = await backupFile.readAsString();
      }
      if (content.trim().isNotEmpty) {
        final json = jsonDecode(content);
        if (json is Map<String, dynamic>) {
          minimizeToTray = json['minimizeToTray'] ?? true;
          launchAtStartup = json['launchAtStartup'] ?? false;
          isFirstLaunch = json['isFirstLaunch'] ?? false;
          autoUpdateIntervalHours = json['autoUpdateIntervalHours'] ?? 0;
          lastSelectedProxy = json['lastSelectedProxy'] ?? '';
          pingMethod = json['pingMethod'] ?? 'api';
          final dynamic secretRaw = json['apiSecret'];
          apiSecret = (secretRaw is String) ? secretRaw : '';
          blurIp.value = json['blurIp'] ?? false;

          final int themeIndex = json['themeMode'] ?? 0;
          themeMode.value = ThemeMode.values.elementAt(themeIndex.clamp(0, 2));

          final dynamic langRaw = json['language'];
          if (langRaw is String && supportedLanguages.contains(langRaw)) {
            language.value = langRaw;
          } else {
            final bool legacyIsEnglish = json['isEnglish'] ?? true;
            language.value = legacyIsEnglish ? 'en' : 'ru';
          }
          seedColor.value = json['seedColor'] ?? 0xFF03A9F4;
          themeVariant.value = json['themeVariant'] ?? 'tonalSpot';
          pureBlack.value = json['pureBlack'] ?? false;
          final dynamic viewRaw = json['proxyViewMode'];
          proxyViewMode.value = viewRaw == 'list' ? 'list' : 'grid';

          final dynamic selRaw = json['groupSelections'];
          groupSelections.clear();
          if (selRaw is Map) {
            selRaw.forEach((key, value) {
              if (key is String && value is String) {
                groupSelections[key] = value;
              }
            });
          }
        }
      }
    } catch (e, stack) {
      debugPrint('Ошибка при загрузке настроек: $e\n$stack');
    }

    // Гарантируем наличие секрета локального API после загрузки (чистая
    // установка, отсутствующие или повреждённые настройки) и сохраняем его,
    // чтобы сгенерированные конфиги и запросы к API всегда использовали одно значение.
    if (apiSecret.isEmpty) {
      apiSecret = _generateSecret();
      saveSettings();
    }
  }

  Future<void> _saveQueue = Future<void>.value();

  // Сериализует все записи настроек, чтобы параллельные вызовы (переключение
  // узлов, переключатели UI) не пересекались на общих файлах .tmp/.bak.

  /// Поставить сохранение настроек в очередь (последовательное выполнение).
  Future<void> saveSettings() {
    final Future<void> next = _saveQueue.then((_) => _saveSettingsInternal());
    _saveQueue = next.catchError((_) {});
    return next;
  }

  /// Атомарная запись настроек: запись в .tmp → переименование, с резервной копией .bak.
  Future<void> _saveSettingsInternal() async {
    try {
      final file = File(await _path);
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }

      final String data = jsonEncode({
        'minimizeToTray': minimizeToTray,
        'launchAtStartup': launchAtStartup,
        'isFirstLaunch': isFirstLaunch,
        'autoUpdateIntervalHours': autoUpdateIntervalHours,
        'lastSelectedProxy': lastSelectedProxy,
        'pingMethod': pingMethod,
        'apiSecret': apiSecret,
        'themeMode': themeMode.value.index,
        'language': language.value,
        'blurIp': blurIp.value,
        'seedColor': seedColor.value,
        'themeVariant': themeVariant.value,
        'pureBlack': pureBlack.value,
        'proxyViewMode': proxyViewMode.value,
        'groupSelections': groupSelections,
      });

      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(data, flush: true);

      final backupFile = File('${file.path}.bak');

      if (await file.exists()) {
        if (await backupFile.exists()) await backupFile.delete();
        await file.rename(backupFile.path);
      }

      try {
        await tmpFile.rename(file.path);
        if (await backupFile.exists()) await backupFile.delete();
      } catch (e) {
        if (await backupFile.exists()) await backupFile.rename(file.path);
        rethrow;
      }
    } catch (e, stack) {
      debugPrint('Ошибка при сохранении настроек: $e\n$stack');
    }
  }

  bool _isUpdatingAutoStart = false;

  // ─── Автозапуск (Windows) ───

  /// Включить/выключить автозапуск: задача schtasks с откатом на запись в реестр HKCU.
  Future<void> updateAutoStart(bool value) async {
    if (_isUpdatingAutoStart) return;
    _isUpdatingAutoStart = true;

    launchAtStartup = value;
    if (!Platform.isWindows) {
      await saveSettings();
      _isUpdatingAutoStart = false;
      return;
    }

    final String exePath = Platform.resolvedExecutable;
    const String taskName = "JustClash";

    try {
      try {
        await Process.run(
            'reg',
            [
              'delete',
              'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run',
              '/v',
              taskName,
              '/f',
            ],
            runInShell: false);
      } catch (_) {}

      try {
        await Process.run(
            'schtasks',
            [
              '/delete',
              '/tn',
              taskName,
              '/f',
            ],
            runInShell: false);
      } catch (_) {}

      if (value) {
        final String normalizedPath = p.normalize(exePath);
        final String escapedPath = '"$normalizedPath"';

        final result = await Process.run(
            'schtasks',
            [
              '/create',
              '/tn',
              taskName,
              '/tr',
              '$escapedPath --elevated',
              '/sc',
              'onlogon',
              '/rl',
              'highest',
              '/f',
            ],
            runInShell: false);

        if (result.exitCode != 0) {
          debugPrint(
            'Не удалось создать задачу в schtasks, применяем запись в реестр HKCU...',
          );
          await Process.run(
              'reg',
              [
                'add',
                'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run',
                '/v',
                taskName,
                '/t',
                'REG_SZ',
                '/d',
                '$escapedPath --elevated',
                '/f',
              ],
              runInShell: false);
        }
      }
    } catch (e, stack) {
      debugPrint('Ошибка при обновлении параметров автозапуска: $e\n$stack');
    } finally {
      _isUpdatingAutoStart = false;
    }

    await saveSettings();
  }
}
