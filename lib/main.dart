// ═══════════════════════════════════════════════════════════════════════════
// main.dart — точка входа и главная оболочка приложения JustClash.
//
// Назначение файла:
//   • Запуск: инициализация, самоповышение прав (UAC), настройка окна.
//   • Главная оболочка: боковая навигация, системный трей, жизненный цикл окна.
//   • Автообновление подписок (принудительный проход при старте + периодический).
//   • Диалог первоначальной установки ядра и Geo-баз.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart' as tray;
import 'package:package_info_plus/package_info_plus.dart';

import 'services/core_controller.dart';
import 'services/settings_service.dart';
import 'services/subscription_parser.dart';
import 'screens/dashboard_screen.dart';
import 'screens/proxies_screen.dart';
import 'screens/profiles_screen.dart';
import 'screens/settings_screen.dart';
import 'services/theme_service.dart';
import 'services/memory_optimizer.dart';

// ─── Точка входа и проверка прав ───

/// Проверяет, запущено ли приложение с правами администратора (net session / fltmc).
Future<bool> _checkIsAdmin() async {
  try {
    final result = await Process.run('net', ['session'], runInShell: true);
    if (result.exitCode == 0) return true;

    final fltmcResult = await Process.run('fltmc', [], runInShell: true);
    return fltmcResult.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Точка входа: инициализация, при необходимости — самоповышение прав (UAC),
/// настройка окна и запуск приложения.
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  await SettingsService().loadSettings();

  if (Platform.isWindows) {
    final bool isElevatedArg = args.contains('--elevated');
    final bool isAdmin = await _checkIsAdmin();

    if (!isAdmin && !isElevatedArg && kReleaseMode) {
      try {
        final String exePath = Platform.resolvedExecutable;
        final String script =
            "Start-Process -FilePath '${exePath.replaceAll("'", "''")}' -ArgumentList '--elevated' -Verb RunAs";

        final Uint8List utf16le = Uint8List(script.length * 2);
        for (int i = 0; i < script.length; i++) {
          utf16le[i * 2] = script.codeUnitAt(i) & 0xFF;
          utf16le[i * 2 + 1] = script.codeUnitAt(i) >> 8;
        }
        final String encoded = base64Encode(utf16le);

        final result = await Process.run('powershell', [
          '-WindowStyle',
          'Hidden',
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          encoded,
        ]);

        if (result.exitCode == 0) {
          exit(0);
        } else {
          debugPrint(
            'Отказ в правах администратора (UAC). Продолжаем без повышения прав.',
          );
        }
      } catch (e) {
        debugPrint('Не удалось запросить права администратора: $e');
      }
    }

    // Единственный экземпляр обеспечивается нативно в windows/runner/main.cpp
    // через именованный мьютекс (он же поднимает уже открытое окно), поэтому
    // блокировка через loopback-порт на стороне Dart здесь не нужна.
    WindowOptions windowOptions = const WindowOptions(
      center: true,
      skipTaskbar: false,
      title: "JustClash",
      size: Size(1000, 650),
      minimumSize: Size(800, 580),
      titleBarStyle: TitleBarStyle.hidden,
    );

    runApp(const JustClashApp());

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setPreventClose(true);
    });
  } else {
    runApp(const JustClashApp());
  }
}

// ─── Корневой виджет приложения и тема ───

/// Поведение прокрутки: разрешает перетаскивание мышью, тачем, трекпадом и пером.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.unknown,
      };
}

/// Корневой виджет: пересобирает MaterialApp при смене темы/акцента/стиля.
class JustClashApp extends StatelessWidget {
  const JustClashApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService();
    return AnimatedBuilder(
      animation: Listenable.merge([
        settings.themeMode,
        settings.seedColor,
        settings.themeVariant,
        settings.pureBlack,
      ]),
      builder: (context, child) {
        final Color seed = Color(settings.seedColor.value);
        final String variant = settings.themeVariant.value;
        final bool pureBlack = settings.pureBlack.value;

        return MaterialApp(
          title: 'JustClash',
          scrollBehavior: const AppScrollBehavior(),
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode.value,
          theme: AppTheme.build(
            brightness: Brightness.light,
            seed: seed,
            variant: variant,
            pureBlack: pureBlack,
          ),
          darkTheme: AppTheme.build(
            brightness: Brightness.dark,
            seed: seed,
            variant: variant,
            pureBlack: pureBlack,
          ),
          home: const MainShell(),
        );
      },
    );
  }
}

// ─── Главная оболочка: навигация, трей, автообновление ───

/// Главная оболочка приложения с боковой навигацией и фоновыми задачами.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

/// Состояние главной оболочки: ядро, системный трей, автообновление подписок
/// и управление жизненным циклом окна.
class _MainShellState extends State<MainShell>
    with WidgetsBindingObserver, WindowListener {
  final CoreController _coreController = CoreController();
  final tray.SystemTray _systemTray = tray.SystemTray();
  int _currentNavIndex = 0;
  bool _isSidebarExpanded = true;
  Timer? _autoUpdateTimer;
  // Защищает принудительное обновление при холодном старте, чтобы перекрывающиеся
  // вызовы не запустили его дважды. Проход «обновить всё» выполняется ТОЛЬКО при
  // полном запуске процесса — никогда при восстановлении из трея / разворачивании.
  bool _forcedUpdateInFlight = false;
  bool _uiSuspended = false;
  String _appVersion = '';

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      DashboardScreen(
        coreController: _coreController,
        onToggleConnect: _handleToggleConnect,
      ),
      ProxiesScreen(coreController: _coreController),
      ProfilesScreen(coreController: _coreController),
      SettingsScreen(coreController: _coreController),
    ];
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    _initSystemTray();
    SettingsService().language.addListener(_updateSystemTrayMenu);
    _coreController.isVpnConnected.addListener(_updateSystemTrayMenu);
    _loadAppVersion();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkFirstLaunchAndSetup();
      _startAutoUpdateTimer();
    });
  }

  /// Запускает принудительное обновление при старте и периодический таймер (15 мин).
  void _startAutoUpdateTimer() {
    bool isCheckingUpdates = false;

    // Возвращает: (-2) другая проверка уже идёт; (-1) пока нечего делать
    // (нет папки профилей / ни у одного профиля нет пригодного URL / интервал
    // отключён без force); (>=0) число профилей, которые реально качались и
    // завершились с ошибкой. Вызывающий код НЕ должен считать «нечего делать»
    // «успехом» — при холодном старте, когда папка профилей ещё не готова,
    // нужно продолжать повторы, пока профили не появятся.
    Future<int> checkUpdates({
      bool forceAll = false,
      Set<String>? alreadyDone,
    }) async {
      if (isCheckingUpdates) return -2;
      isCheckingUpdates = true;
      int failures = 0;
      int fetched = 0;
      try {
        final int interval = SettingsService().autoUpdateIntervalHours;
        if (!forceAll && interval <= 0) return -1;

        final Directory docDir = await getApplicationDocumentsDirectory();
        final Directory profilesDir = Directory(
          p.join(docDir.path, 'JustClash', 'profiles'),
        );
        if (!await profilesDir.exists()) return -1;

        // Определяем активный профиль, чтобы принудительный проход при холодном
        // старте детерминированно перезагрузил его свежескачанный конфиг в ядро
        // (иначе mihomo может крутить устаревший файл до следующего перезапуска —
        // баг «обновляется только со второго перезапуска»).
        String activeFileName = 'config.yaml';
        try {
          final File activeMarker = File(
            p.join(docDir.path, 'JustClash', 'active_profile.txt'),
          );
          if (await activeMarker.exists()) {
            final String marker = (await activeMarker.readAsString()).trim();
            if (marker.isNotEmpty) activeFileName = marker;
          }
        } catch (_) {}
        bool activeRefreshed = false;

        final List<File> metaFiles = (await profilesDir.list().toList())
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList();
        final int nowMs = DateTime.now().millisecondsSinceEpoch;

        for (final metaFile in metaFiles) {
          final String shortName = p.basenameWithoutExtension(metaFile.path);
          if (alreadyDone != null && alreadyDone.contains(shortName)) continue;
          String? url;
          try {
            final decoded = jsonDecode(await metaFile.readAsString());
            if (decoded is! Map) continue;
            url = decoded['subscription_url']?.toString();
            final int lastUpdate = (decoded['last_update'] is num)
                ? (decoded['last_update'] as num).toInt()
                : 0;
            final double elapsedHours = (nowMs - lastUpdate) / (1000 * 60 * 60);
            final double elapsedMinutes = (nowMs - lastUpdate) / (1000 * 60);
            // Даже при принудительном проходе холодного старта пропускаем
            // подписки, обновлённые буквально только что (последние ~2 минуты).
            // Это убирает гонку самого первого запуска: фоновой проход
            // обновить всё дожидается появления профилей и, как только
            // пользователь импортировал подписку, повторно её скачивал и горячо
            // перезагружал ядро ровно в тот момент, когда пользователь выбирал
            // локацию и подключался. Свежеподнятый туннель из-за этого
            // сбрасывался, ядро останавливалось через пару секунд, а кнопка
            // зависала на Подключение. Свежеимпортированный или только что
            // синхронизированный профиль и так актуален — немедленная
            // перекачка ему не нужна.
            const double freshSkipMinutes = 2.0;
            if (url == null ||
                url.isEmpty ||
                (!forceAll && elapsedHours < interval) ||
                (forceAll && elapsedMinutes < freshSkipMinutes)) {
              continue;
            }
          } catch (e) {
            debugPrint(
              'Автообновление: не удалось прочитать мету $shortName: $e',
            );
            continue;
          }

          if (forceAll && mounted) {
            // Зажигаем индикаторы обновления ровно в момент, когда профиль прошёл
            // все проверки пропуска и его подписка сейчас будет реально скачана.
            // Так анимация на экране «Профили» (общий ползунок + вращение значка)
            // отражает настоящую активность обновления, а не сам факт запуска
            // принудительного прохода. Если все профили пропущены (свежие или без
            // URL), флаг остаётся false и фантомного спиннера больше нет.
            _coreController.isRefreshingSubscriptions.value = true;
            _coreController.refreshingProfileFile.value = '$shortName.yaml';
          }

          // Запоминаем конфиг ДО загрузки: перезагружать ядро нужно ТОЛЬКО при
          // реальном изменении подписки. Лишний hot-reload пересоздаёт TUN и
          // рвёт уже поднятый туннель — именно это «роняло» ядро через 30-40 c
          // после подключения сразу за перезагрузкой системы (стартовый проход
          // перекачивал ту же подписку и зря перезагружал активный конфиг).
          final String targetPath = p.join(profilesDir.path, '$shortName.yaml');
          String? previousConfig;
          try {
            final File prevFile = File(targetPath);
            if (await prevFile.exists()) {
              previousConfig = await prevFile.readAsString();
            }
          } catch (_) {}

          try {
            await SubscriptionParser().fetchAndSaveSubscription(url, shortName);
          } catch (e) {
            failures++;
            debugPrint('Автообновление: сбой загрузки $shortName: $e');
            continue;
          }
          fetched++;
          alreadyDone?.add(shortName);

          // Изменился ли конфиг после загрузки (побайтовое сравнение). Если
          // подписка вернула тот же конфиг — ядро не трогаем, туннель остаётся.
          bool configChanged = true;
          try {
            final File newFile = File(targetPath);
            if (previousConfig != null && await newFile.exists()) {
              final String newConfig = await newFile.readAsString();
              configChanged = newConfig != previousConfig;
            }
          } catch (_) {}

          if (configChanged &&
              '$shortName.yaml'.toLowerCase() == activeFileName.toLowerCase()) {
            activeRefreshed = true;
          }

          try {
            if (!mounted) continue;
            final String activePath = _coreController.currentConfigPath ?? '';
            if (configChanged &&
                _coreController.isRunning.value &&
                activePath.toLowerCase() == targetPath.toLowerCase()) {
              await _coreController.hotReloadConfig(targetPath);
            }
          } catch (e) {
            debugPrint('Автообновление: сбой hot-reload $shortName: $e');
          }
        }

        // Детерминированно применяем свежескачанный АКТИВНЫЙ профиль к ядру при
        // принудительном проходе холодного старта. Ядро может ещё запускаться
        // (bootstrap), поэтому коротко ждём его готовности, затем горячо
        // перезагружаем свежий конфиг. Это убирает гонку запуска/загрузки, из-за
        // которой устаревший конфиг жил до СЛЕДУЮЩЕГО перезапуска.
        if (forceAll && activeRefreshed && mounted) {
          final String activeTargetPath =
              p.join(profilesDir.path, activeFileName);
          if (await File(activeTargetPath).exists()) {
            for (int i = 0; i < 30; i++) {
              if (!mounted || _coreController.isRunning.value) break;
              await Future.delayed(const Duration(milliseconds: 500));
            }
            try {
              if (mounted &&
                  _coreController.isRunning.value &&
                  (_coreController.currentConfigPath ?? '').toLowerCase() ==
                      activeTargetPath.toLowerCase()) {
                await _coreController.hotReloadConfig(activeTargetPath);
              }
            } catch (e) {
              debugPrint(
                'Автообновление: сбой применения активного профиля: $e',
              );
            }
          }
        }

        // Если ни один профиль даже не пробовали — сообщаем «нечего делать»,
        // чтобы цикл холодного старта продолжал повторы, пока не появятся меты.
        if (fetched == 0 && failures == 0) return -1;
        return failures;
      } catch (e) {
        debugPrint('Автообновление: сбой цикла: $e');
        return -1;
      } finally {
        isCheckingUpdates = false;
      }
    }

    /// Однократный (на запуск процесса) принудительный проход обновления всех
    /// подписок с длинным backoff на случай отсутствия сети.
    Future<void> runInitialForcedCheck() async {
      // Этот принудительный проход «обновить каждую подписку» выполняется ТОЛЬКО
      // один раз за полный запуск процесса (холодный старт). Он намеренно НЕ
      // привязан к восстановлению из трея / разворачиванию — повторное открытие
      // окна никогда не должно обновлять подписки. Сеть может быть не готова сразу
      // после запуска, поэтому повторяем с длинным backoff, чтобы переждать
      // отсутствие связи, и сначала дожидаемся конца уже идущей пассивной
      // проверки, чтобы её ранний возврат 0 не приняли за успех. Уже обновлённые
      // профили запоминаются в `done` и пропускаются при повторах, так что одна
      // «мёртвая» подписка не перекачивает здоровые на каждом проходе. Мы также
      // продолжаем повторы, пока checkUpdates сообщает «нечего делать» (-1): при
      // свежем холодном старте меты могут быть ещё не записаны, поэтому первый
      // проход законно ничего не находит — прежний код здесь сдавался и обновлял
      // лишь со следующего перезапуска приложения.
      if (_forcedUpdateInFlight) return;
      _forcedUpdateInFlight = true;
      // НЕ включаем индикатор обновления заранее. Спиннер на экране «Профили»
      // должен загораться только когда реально начинается загрузка хотя бы одной
      // подписки. Иначе при полном перезапуске, когда все подписки ещё «свежие»
      // (моложе freshSkipMinutes) и checkUpdates по факту ничего не качает,
      // пользователь видел вращение «как будто идёт обновление», хотя ни одна
      // подписка не обновлялась. Теперь флаг выставляется внутри checkUpdates
      // ровно перед фактическим fetch (см. блок ниже), а здесь лишь сбрасывается
      // при повторных попытках и в finally.
      try {
        const List<Duration> backoff = [
          Duration(seconds: 3),
          Duration(seconds: 8),
          Duration(seconds: 20),
          Duration(seconds: 45),
          Duration(seconds: 90),
          Duration(seconds: 180),
          Duration(seconds: 180),
          Duration(seconds: 180),
        ];
        final Set<String> done = <String>{};
        for (int attempt = 0; attempt <= backoff.length; attempt++) {
          if (!mounted) return;
          while (isCheckingUpdates) {
            await Future.delayed(const Duration(milliseconds: 300));
            if (!mounted) return;
          }
          final int result = await checkUpdates(
            forceAll: true,
            alreadyDone: done,
          );
          // result == -2: пассивная проверка в процессе; повторяем эту попытку.
          // result == -1: ни один профиль ещё не готов; повторяем до их появления.
          // result ==  0: все доступные профили обновлены без ошибок -> готово.
          // result  >  0: часть профилей не удалась; продолжаем повторы по backoff.
          if (result == 0) return;
          if (attempt == backoff.length) return;
          // Перестаём показывать индикатор обновления после первых пары видимых
          // попыток, чтобы стабильно падающая или офлайн-подписка не крутила
          // спиннер на экране «Профили» минутами. Повторы продолжаются тихо в
          // фоне по расписанию backoff.
          if (attempt >= 1 && mounted) {
            _coreController.isRefreshingSubscriptions.value = false;
            _coreController.refreshingProfileFile.value = null;
          }
          await Future.delayed(backoff[attempt]);
        }
      } finally {
        _forcedUpdateInFlight = false;
        if (mounted) {
          _coreController.isRefreshingSubscriptions.value = false;
          _coreController.refreshingProfileFile.value = null;
        }
      }
    }

    runInitialForcedCheck();
    _autoUpdateTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => checkUpdates(),
    );
  }

  /// При первом запуске или отсутствии ядра/Geo-баз показывает диалог установки;
  /// иначе сразу запускает ядро.
  Future<void> _checkFirstLaunchAndSetup() async {
    final corePath = await _coreController.getAbsoluteCorePath();
    final geoPath = await _coreController.getAbsoluteGeoDbPath();
    final coreExists = await File(corePath).exists();
    final geoExists = await File(geoPath).exists();

    if (SettingsService().isFirstLaunch || !coreExists || !geoExists) {
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              SetupComponentDialog(coreController: _coreController),
        ).then((_) {
          if (!mounted) return;
          SettingsService().isFirstLaunch = false;
          SettingsService().saveSettings();
          _bootstrapCoreOnStartup();
        });
      }
    } else {
      _bootstrapCoreOnStartup();
    }
  }

  @override
  void dispose() {
    _autoUpdateTimer?.cancel();
    SettingsService().language.removeListener(_updateSystemTrayMenu);
    _coreController.isVpnConnected.removeListener(_updateSystemTrayMenu);
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    _coreController.dispose().catchError((e) {
      debugPrint('Ошибка при dispose CoreController: $e');
    });
    _systemTray.destroy().catchError((e) {
      debugPrint('Ошибка при уничтожении системного трея: $e');
    });
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (SettingsService().minimizeToTray) {
      await windowManager.hide();
      _setUiSuspended(true);
    } else {
      await windowManager.hide();
      await _shutdownAndExit();
    }
  }

  /// Останавливает ядро, уничтожает трей и завершает процесс.
  Future<void> _shutdownAndExit() async {
    try {
      await _coreController.stopCore().timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await _coreController.killCoreImmediately();
    } catch (_) {}
    try {
      await _systemTray.destroy();
    } catch (_) {}
    exit(0);
  }

  /// Перестраивает контекстное меню системного трея на текущем языке.
  Future<void> _updateSystemTrayMenu() async {
    try {
      final s = SettingsService();
      final menu = tray.Menu();
      await menu.buildFrom([
        tray.MenuItemLabel(
          label: s.tr('Показать', 'Show', '显示'),
          onClicked: (menuItem) async {
            await windowManager.show();
            await windowManager.focus();
            _setUiSuspended(false);
          },
        ),
        tray.MenuItemLabel(
          label: s.tr('Скрыть', 'Hide', '隐藏'),
          onClicked: (menuItem) async {
            await windowManager.hide();
            _setUiSuspended(true);
          },
        ),
        tray.MenuSeparator(),
        tray.MenuItemLabel(
          label: s.tr('Подключиться', 'Connect', '连接'),
          onClicked: (menuItem) async =>
              await _coreController.setVpnMode('Rule'),
        ),
        tray.MenuItemLabel(
          label: s.tr('Отключиться', 'Disconnect', '断开'),
          onClicked: (menuItem) async =>
              await _coreController.setVpnMode('Direct'),
        ),
        tray.MenuSeparator(),
        tray.MenuItemLabel(
          label: s.tr('Выход', 'Exit', '退出'),
          onClicked: (menuItem) async {
            await windowManager.hide();
            await _shutdownAndExit();
          },
        ),
      ]);
      await _systemTray.setContextMenu(menu);
    } catch (_) {}
  }

  /// Подбирает путь к иконке трея (серая tray_icon.ico, иначе icon.ico).
  String _resolveTrayIconPath() {
    try {
      final String exeDir = p.dirname(Platform.resolvedExecutable);
      final String assetsDir = p.join(
        exeDir,
        'data',
        'flutter_assets',
        'assets',
      );
      final String grayTray = p.join(assetsDir, 'tray_icon.ico');
      if (File(grayTray).existsSync()) return grayTray;
      final String bundled = p.join(assetsDir, 'icon.ico');
      if (File(bundled).existsSync()) return bundled;
    } catch (_) {}
    return 'assets/icon.ico';
  }

  /// Инициализирует системный трей и обработчик кликов (показать/скрыть окно).
  Future<void> _initSystemTray() async {
    try {
      await _systemTray.initSystemTray(
        title: "JustClash",
        iconPath: _resolveTrayIconPath(),
      );

      await _updateSystemTrayMenu();

      _systemTray.registerSystemTrayEventHandler((eventName) async {
        if (eventName == tray.kSystemTrayEventClick) {
          bool isVisible = await windowManager.isVisible();
          if (isVisible) {
            await windowManager.hide();
            _setUiSuspended(true);
          } else {
            await windowManager.show();
            await windowManager.focus();
            _setUiSuspended(false);
          }
        } else if (eventName == tray.kSystemTrayEventRightClick) {
          await _systemTray.popUpContextMenu();
        }
      });
    } catch (e) {
      debugPrint("Не удалось инициализировать системный трей: $e");
    }
  }

  /// Запускает ядро с активным профилем при старте, если его файл существует.
  Future<void> _bootstrapCoreOnStartup() async {
    try {
      final Directory docDir = await getApplicationDocumentsDirectory();
      final String basePath = p.join(docDir.path, 'JustClash');

      String profileFileName = 'config.yaml';
      final File activeMarker = File(p.join(basePath, 'active_profile.txt'));
      if (await activeMarker.exists()) {
        final content = (await activeMarker.readAsString()).trim();
        if (content.isNotEmpty) profileFileName = content;
      }

      if (!mounted) return;

      final String configPath = p.join(basePath, 'profiles', profileFileName);
      if (File(configPath).existsSync()) {
        await _coreController.startCore(configPath);
        if (!mounted) return;
        if (_currentNavIndex != 0) {
          _coreController.stopStatsTracking();
        }
      }
    } catch (e) {
      debugPrint('Ошибка автозапуска ядра: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _setUiSuspended(true);
    } else if (state == AppLifecycleState.resumed) {
      _setUiSuspended(false);
    }
  }

  @override
  void onWindowMinimize() {
    _setUiSuspended(true);
  }

  @override
  void onWindowRestore() {
    _setUiSuspended(false);
  }

  /// Приостанавливает/возобновляет фоновую активность UI (статистика, таймер)
  /// при сворачивании в трей и восстановлении.
  void _setUiSuspended(bool suspended) {
    if (_uiSuspended == suspended) return;
    if (suspended) {
      _coreController.stopStatsTracking();
      _coreController.pauseConnectionTimer();
      // Возвращаем системе физическую память (рабочий набор) при сворачивании
      // в трей / минимизации. Flutter-движок держит в ОЗУ ~100 МБ кадровых
      // буферов и арен Skia даже когда окно скрыто и ничего не рисуется;
      // SetProcessWorkingSetSize отдаёт эти страницы ОС, и в фоне процесс
      // занимает единицы МБ (как в прежних версиях). При разворачивании
      // страницы подгружаются обратно. Небольшая задержка даёт движку сначала
      // освободить кадровые ресурсы после скрытия окна.
      MemoryOptimizer.trimWorkingSet(delay: const Duration(seconds: 2));
    } else {
      _coreController.resumeConnectionTimer();
      if (_currentNavIndex == 0) {
        _coreController.startStatsTracking();
      }
      // ВАЖНО: восстановление из трея / разворачивание намеренно НЕ обновляет
      // подписки. Проход «обновить всё» выполняется только при полном запуске
      // процесса (см. runInitialForcedCheck). Пассивные обновления по интервалу
      // обрабатываются исключительно периодическим таймером и пользовательской
      // настройкой интервала автообновления.
    }
    if (!mounted) {
      _uiSuspended = suspended;
      return;
    }
    setState(() {
      _uiSuspended = suspended;
    });
  }

  /// Переключает VPN (Rule/Direct), игнорируя нажатия во время уже идущего
  /// подключения/отключения.
  Future<void> _handleToggleConnect() async {
    // Игнорируем нажатия, пока подключение/отключение уже выполняется. Раньше
    // быстрые повторные нажатия могли войти в гонку с переключением TUN при
    // холодном старте — из-за чего после перезапуска туннель поднимался лишь
    // через несколько кликов.
    if (_coreController.isToggling.value) return;
    if (_coreController.isVpnConnected.value) {
      await _coreController.setVpnMode('Direct');
    } else {
      await _coreController.setVpnMode('Rule');
    }
  }

  /// Переключает активную вкладку и включает/выключает сбор статистики.
  void _onDestinationSelected(int index) {
    setState(() {
      _currentNavIndex = index;
    });
    if (index == 0) {
      _coreController.startStatsTracking();
    } else {
      _coreController.stopStatsTracking();
    }
  }

  /// Загружает версию приложения из метаданных пакета.
  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _appVersion = info.version);
      }
    } catch (e) {
      debugPrint('Не удалось получить версию приложения: $e');
    }
  }

  // ─── Боковая панель ───

  /// Заголовок боковой панели: логотип, версия и сворачивание/разворачивание.
  Widget _buildSidebarHeader(bool isDark) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => setState(() => _isSidebarExpanded = !_isSidebarExpanded),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Container(
        padding: EdgeInsets.only(
          top: 24,
          bottom: 20,
          left: _isSidebarExpanded ? 20 : 0,
          right: _isSidebarExpanded ? 16 : 0,
        ),
        alignment: _isSidebarExpanded ? Alignment.centerLeft : Alignment.center,
        child: Row(
          mainAxisAlignment: _isSidebarExpanded
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Image.asset(
                'assets/icon.ico',
                width: 20,
                height: 20,
                filterQuality: FilterQuality.high,
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Icons.security, color: accent, size: 18),
              ),
            ),
            if (_isSidebarExpanded) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_appVersion.isNotEmpty)
                      Text(
                        _appVersion,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: TextStyle(
                          color: isDark ? Colors.white38 : Colors.black38,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    Text(
                      "JustClash",
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black87,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Элемент навигации боковой панели с активным состоянием.
  Widget _buildSidebarItem({
    required int index,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    final bool isActive = _currentNavIndex == index;
    final Color accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: EdgeInsets.symmetric(
            horizontal: _isSidebarExpanded ? 12 : 14,
            vertical: 4,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: _isSidebarExpanded ? 16 : 0,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            color: isActive
                ? accent.withValues(alpha: isDark ? 0.18 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: isActive
                ? Border.all(color: accent.withValues(alpha: 0.25))
                : null,
          ),
          child: Row(
            mainAxisAlignment: _isSidebarExpanded
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color:
                    isActive ? accent : (isDark ? Colors.grey : Colors.black54),
                size: 18,
              ),
              if (_isSidebarExpanded) ...[
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: TextStyle(
                      color: isActive
                          ? (isDark ? Colors.white : Colors.black87)
                          : (isDark ? Colors.grey : Colors.black54),
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (isActive)
                  Container(
                    width: 3,
                    height: 14,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Нижний блок боковой панели: индикатор состояния подключения (TUN).
  Widget _buildSidebarBottom(bool isDark) {
    final Color accent = Theme.of(context).colorScheme.primary;
    final s = SettingsService();
    return Container(
      padding: EdgeInsets.all(_isSidebarExpanded ? 16 : 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white10 : Colors.black12,
            width: 0.5,
          ),
        ),
      ),
      child: ValueListenableBuilder<bool>(
        valueListenable: _coreController.isVpnConnected,
        builder: (context, isConnected, child) {
          final Color dotColor =
              isConnected ? accent : Colors.grey.withValues(alpha: 0.5);
          final Widget statusDot = AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: isConnected
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : [],
            ),
          );

          if (!_isSidebarExpanded) {
            return Center(child: statusDot);
          }

          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isConnected
                  ? accent.withValues(alpha: isDark ? 0.12 : 0.08)
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.black.withValues(alpha: 0.03)),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isConnected
                    ? accent.withValues(alpha: 0.30)
                    : (isDark ? Colors.white10 : Colors.black12),
              ),
            ),
            child: Row(
              children: [
                statusDot,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isConnected
                        ? s.tr(
                            'Режим TUN активен',
                            'TUN Mode Active',
                            'TUN 模式已启用',
                          )
                        : s.tr('Отключено', 'Disconnected', '已断开'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: TextStyle(
                      fontSize: 11,
                      color: isConnected
                          ? (isDark ? Colors.white : Colors.black87)
                          : (isDark ? Colors.white54 : Colors.black54),
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: _uiSuspended,
      child: ValueListenableBuilder<String>(
        valueListenable: SettingsService().language,
        builder: (context, lang, child) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final s = SettingsService();

          return Scaffold(
            body: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: _isSidebarExpanded ? 220 : 70,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF111315) : Colors.white,
                    border: Border(
                      right: BorderSide(
                        color: isDark ? Colors.white10 : Colors.black12,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildSidebarHeader(isDark),
                      Expanded(
                        child: ListView(
                          physics: const BouncingScrollPhysics(),
                          children: [
                            _buildSidebarItem(
                              index: 0,
                              icon: Icons.dashboard_outlined,
                              label: s.tr('Главная', 'Dashboard', '主页'),
                              onTap: () => _onDestinationSelected(0),
                              isDark: isDark,
                            ),
                            _buildSidebarItem(
                              index: 1,
                              icon: Icons.network_ping,
                              label: s.tr('Прокси', 'Proxies', '代理'),
                              onTap: () => _onDestinationSelected(1),
                              isDark: isDark,
                            ),
                            _buildSidebarItem(
                              index: 2,
                              icon: Icons.folder_open,
                              label: s.tr('Профили', 'Profiles', '配置'),
                              onTap: () => _onDestinationSelected(2),
                              isDark: isDark,
                            ),
                            _buildSidebarItem(
                              index: 3,
                              icon: Icons.settings_outlined,
                              label: s.tr('Настройки', 'Settings', '设置'),
                              onTap: () => _onDestinationSelected(3),
                              isDark: isDark,
                            ),
                          ],
                        ),
                      ),
                      _buildSidebarBottom(isDark),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      const CustomTitleBar(),
                      Expanded(
                        child: IndexedStack(
                          index: _currentNavIndex,
                          children: _screens,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─── Заголовок окна и кнопки управления ───

/// Кастомная строка заголовка окна с областью перетаскивания и кнопками.
class CustomTitleBar extends StatelessWidget {
  const CustomTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Container(
                padding: const EdgeInsets.only(left: 16),
                alignment: Alignment.centerLeft,
                child: const Row(children: []),
              ),
            ),
          ),
          const WindowButtons(),
        ],
      ),
    );
  }
}

/// Кнопки управления окном: свернуть, развернуть/восстановить, закрыть.
class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDark ? Colors.white70 : Colors.black54;
    final hoverBg = isDark ? Colors.white10 : Colors.black12;

    return Row(
      children: [
        _buildButton(
          icon: Icons.minimize,
          iconSize: 14,
          iconColor: iconColor,
          hoverColor: hoverBg,
          onTap: () => windowManager.minimize(),
        ),
        _buildButton(
          icon: Icons.crop_square,
          iconSize: 12,
          iconColor: iconColor,
          hoverColor: hoverBg,
          onTap: () async {
            if (await windowManager.isMaximized()) {
              windowManager.unmaximize();
            } else {
              windowManager.maximize();
            }
          },
        ),
        _buildButton(
          icon: Icons.close,
          iconSize: 14,
          iconColor: iconColor,
          hoverColor: Colors.redAccent.withValues(alpha: 0.8),
          onTap: () => windowManager.close(),
        ),
      ],
    );
  }

  Widget _buildButton({
    required IconData icon,
    required double iconSize,
    required Color iconColor,
    required VoidCallback onTap,
    Color? hoverColor,
  }) {
    return InkWell(
      onTap: onTap,
      hoverColor: hoverColor,
      child: SizedBox(
        width: 46,
        height: 36,
        child: Icon(icon, size: iconSize, color: iconColor),
      ),
    );
  }
}

// ─── Диалог первоначальной установки компонентов ───

/// Диалог первоначальной установки: выбор языка и извлечение ядра и Geo-баз.
class SetupComponentDialog extends StatefulWidget {
  final CoreController coreController;
  const SetupComponentDialog({super.key, required this.coreController});

  @override
  State<SetupComponentDialog> createState() => _SetupComponentDialogState();
}

/// Состояние диалога установки: шаг (язык/установка), статус и ошибки.
class _SetupComponentDialogState extends State<SetupComponentDialog> {
  int _step = 0;
  String _status = 'Initializing...';
  bool _isProcessing = false;
  bool _hasError = false;

  /// Запускает установку: извлекает локальное ядро и базы GeoIP, показывая прогресс.
  void _startSetup() async {
    setState(() {
      _step = 1;
      _isProcessing = true;
      _hasError = false;
    });

    final s = SettingsService();

    try {
      if (mounted) {
        setState(
          () => _status = s.tr(
            'Извлечение локального ядра...',
            'Extracting local core...',
            '正在解压本地核心...',
          ),
        );
      }
      await widget.coreController.ensureCoreExists();

      if (mounted) {
        setState(
          () => _status = s.tr(
            'Извлечение локальной базы GeoIP...',
            'Extracting local GeoIP...',
            '正在解压本地 GeoIP...',
          ),
        );
      }
      final dir = await widget.coreController.getCurrentConfigDir();
      await widget.coreController.ensureGeoDatabase(dir, forceUpdate: false);

      if (mounted) {
        setState(() {
          _status = s.tr('Установка завершена!', 'Setup complete!', '设置完成！');
          _isProcessing = false;
        });
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) Navigator.of(context).pop();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = s.tr('Ошибка: $e', 'Error: $e', '错误：$e');
          _isProcessing = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    if (!SettingsService().isFirstLaunch) {
      _step = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startSetup();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: isDark ? const Color(0xFF1E2227) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        // Ограничиваем диалог шириной содержимого, чтобы шаг выбора языка
        // (три короткие кнопки) и шаг установки не растягивались на всё окно с
        // большими пустыми боковыми отступами. 320 комфортно вмещает
        // «English / Русский / 中文» без переноса.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _step == 0
                  ? _buildLanguageSelection(isDark)
                  : _buildSetupProcess(isDark),
            ),
          ),
        ),
      ),
    );
  }

  /// Шаг выбора языка интерфейса.
  Widget _buildLanguageSelection(bool isDark) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      key: const ValueKey('lang_step'),
      children: [
        Icon(Icons.language, size: 36, color: accent.withValues(alpha: 0.8)),
        const SizedBox(height: 16),
        Text(
          'Select Language',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Please select your preferred language to continue.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _langButton('English', 'en'),
            const SizedBox(width: 8),
            _langButton('Русский', 'ru'),
            const SizedBox(width: 8),
            _langButton('中文', 'zh'),
          ],
        ),
      ],
    );
  }

  /// Кнопка выбора языка, запускающая установку после выбора.
  Widget _langButton(String title, String code) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return _LanguageButton(
      title: title,
      accent: accent,
      onTap: () {
        SettingsService().setLanguage(code);
        _startSetup();
      },
    );
  }

  /// Шаг установки: индикатор прогресса, статус и кнопка повтора при ошибке.
  Widget _buildSetupProcess(bool isDark) {
    final s = SettingsService();
    final Color accent = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      key: const ValueKey('setup_step'),
      children: [
        Icon(
          _hasError ? Icons.error_outline : Icons.system_update_alt,
          size: 48,
          color: _hasError ? Colors.redAccent : accent.withValues(alpha: 0.8),
        ),
        const SizedBox(height: 24),
        Text(
          s.tr('Первоначальная настройка', 'Initial Setup', '初始设置'),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _status,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
        const SizedBox(height: 24),
        if (_isProcessing) CircularProgressIndicator(color: accent),
        if (_hasError)
          ElevatedButton(
            onPressed: _startSetup,
            style: ElevatedButton.styleFrom(backgroundColor: accent),
            child: Text(
              s.tr('Повторить', 'Retry', '重试'),
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
    );
  }
}

// ─── Кнопка выбора языка ───

/// Самодостаточная кнопка выбора языка со стабильным состоянием наведения.
///
/// Прежняя реализация использовала [StatefulBuilder] с локальной переменной
/// `bool isHovering = false`, объявленной *внутри* замыкания builder. Эта
/// переменная пересоздавалась при каждой перестройке, поэтому как только
/// анимация наведения срабатывала и вызывала `setState`, флаг сбрасывался в
/// `false`, анимация откатывалась, а следующее событие указателя снова
/// ставило `true` — отсюда видимое «дрожание». Перенос состояния наведения в
/// настоящее поле [State] сохраняет его между перестройками, поэтому
/// [AnimatedContainer] переходит плавно.
class _LanguageButton extends StatefulWidget {
  const _LanguageButton({
    required this.title,
    required this.accent,
    required this.onTap,
  });

  final String title;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_LanguageButton> createState() => _LanguageButtonState();
}

/// Состояние кнопки языка: хранит флаг наведения между перестройками.
class _LanguageButtonState extends State<_LanguageButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _isHovering
                ? widget.accent.withValues(alpha: 0.18)
                : widget.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _isHovering
                  ? widget.accent.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Text(
            widget.title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: widget.accent,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
