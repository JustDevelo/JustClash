// ═══════════════════════════════════════════════════════════════════════════
//  CoreController
//  Управление ядром Mihomo (Clash.Meta): запуск/остановка процесса, горячая
//  перезагрузка конфигурации, переключение режима VPN (TUN), измерение пинга,
//  работа с группами прокси и обновление гео-баз.
//
//  Все обращения к ядру идут через локальный REST API (external-controller).
//  Тяжёлые операции защищены мьютексами, чтобы параллельные вызовы не
//  конфликтовали. Класс является источником реактивного состояния
//  (ValueNotifier) для всего UI: статус ядра, подключение, скорость, IP и т.д.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';
import 'settings_service.dart';

// ─── Мьютекс (последовательное выполнение критических секций) ───

/// Простой асинхронный мьютекс: выстраивает операции в очередь, чтобы они
/// выполнялись строго по одной. Поддерживает таймаут и флаг отмены, который
/// критическая секция может проверять, чтобы досрочно прерваться.
class _Mutex {
  Completer<void>? _current;

  Future<T> protect<T>(
    Future<T> Function(bool Function() isCancelled) criticalSection, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final completer = Completer<void>();
    final previous = _current;
    _current = completer;

    bool isCancelledFlag = false;
    final timer = Timer(timeout, () {
      isCancelledFlag = true;
    });

    try {
      if (previous != null) {
        try {
          await previous.future.timeout(timeout);
        } on TimeoutException {
          isCancelledFlag = true;
        } catch (_) {}
      }

      if (isCancelledFlag) {
        throw TimeoutException('Очередь мьютекса превысила лимит ожидания.');
      }

      return await criticalSection(() => isCancelledFlag);
    } finally {
      timer.cancel();
      completer.complete();
      if (_current == completer) {
        _current = null;
      }
    }
  }
}

// ─── HTTP-клиент с авторизацией ───

/// Обёртка над http.Client, которая автоматически добавляет локальный секрет
/// API как Bearer-токен в каждый запрос к external-controller ядра. Если
/// секрет не задан, заголовок не добавляется (старые конфиги без секрета
/// продолжают работать без изменений).
class _AuthClient extends http.BaseClient {
  _AuthClient(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final String secret = SettingsService().apiSecret;
    if (secret.isNotEmpty && !request.headers.containsKey('Authorization')) {
      request.headers['Authorization'] = 'Bearer $secret';
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

// ─── Прогресс загрузки гео-баз ───

/// Снимок прогресса скачивания одного гео-файла (имя файла, его номер в общей
/// очереди, принятые/всего байты и текущая скорость) для отображения в UI.
class GeoUpdateProgress {
  final String fileName;
  final int fileIndex;
  final int totalFiles;
  final int received;
  final int total;
  final double speedBytesPerSec;
  const GeoUpdateProgress({
    required this.fileName,
    required this.fileIndex,
    required this.totalFiles,
    required this.received,
    required this.total,
    required this.speedBytesPerSec,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
//  CoreController — основной контроллер ядра
// ═══════════════════════════════════════════════════════════════════════════

/// Контроллер жизненного цикла ядра Mihomo и реактивного состояния VPN.
class CoreController {
  Process? _process;
  String? _currentConfigPath;
  final _Mutex _geoMutex = _Mutex();
  final _Mutex _coreExtractMutex = _Mutex();
  String? get currentConfigPath => _currentConfigPath;

  /// Стабильный ключ профиля (имя файла без расширения) для привязки
  /// сохранённого выбора узлов по группам к конкретному профилю.
  String? get _profileKey => _currentConfigPath == null
      ? null
      : p.basenameWithoutExtension(_currentConfigPath!);
  String _cachedControllerAddr = '127.0.0.1:9090';

  final _Mutex _mutex = _Mutex();

  final ValueNotifier<bool> isRunning = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isVpnConnected = ValueNotifier<bool>(false);

  /// true, пока идёт переключение режима (подключение/отключение TUN).
  /// Используется для индикации «подключение…» на дашборде и защиты от частых
  /// повторных нажатий, которые раньше требовали несколько кликов для связи.
  final ValueNotifier<bool> isToggling = ValueNotifier<bool>(false);
  final ValueNotifier<int> configVersion = ValueNotifier<int>(0);
  final ValueNotifier<String> activeSourceType = ValueNotifier<String>('none');

  /// Наблюдаемое состояние обновления подписок. Устанавливается тем, кто
  /// запускает обновление (вручную на экране профилей или автоматически при
  /// холодном старте в main.dart), чтобы любой экран показывал один и тот же
  /// индикатор загрузки. Раньше обновление при старте шло молча, без UI.
  final ValueNotifier<bool> isRefreshingSubscriptions =
      ValueNotifier<bool>(false);
  final ValueNotifier<String?> refreshingProfileFile =
      ValueNotifier<String?>(null);

  final ValueNotifier<GeoUpdateProgress?> geoProgress =
      ValueNotifier<GeoUpdateProgress?>(null);

  final ValueNotifier<int> connectedSeconds = ValueNotifier<int>(0);
  final ValueNotifier<String> currentIp = ValueNotifier<String>('...');
  Timer? _connectionTimer;
  Timer? _ipTimer;
  DateTime? _connectionStartTime;

  CoreController() {
    isVpnConnected.addListener(() {
      if (isVpnConnected.value) {
        _connectionStartTime = DateTime.now();
        _startConnectionTicker();
        currentIp.value = '...';
        fetchCurrentIp();
        // НАМЕРЕННО не запускаем обновление гео-баз ядра в момент подключения.
        // POST /upgrade/geo заставляет ядро перечитать гео-данные и применить
        // их на лету; на самом первом запуске это совпадало с только что
        // поднятым TUN-туннелем и могло его сбросить (ядро «подключается
        // и через пару секунд останавливается»). Гео-базы и так покрыты двумя
        // надёжными механизмами: извлечением из ассетов в ensureGeoDatabase()
        // при каждом старте ядра и штатным фоновым обновлением самого
        // ядра (geo-auto-update: true, geo-update-interval: 24 в конфиге). Поэтому
        // отдельный ручной триггер на коннекте избыточен и только создавал риск.
      } else {
        _connectionTimer?.cancel();
        _connectionTimer = null;
        _connectionStartTime = null;
        connectedSeconds.value = 0;
        currentIp.value = '...';
        fetchCurrentIp();
      }
    });
  }

  void _startConnectionTicker() {
    _connectionTimer?.cancel();
    _recomputeConnectedSeconds();
    _connectionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _recomputeConnectedSeconds();
    });
  }

  void _recomputeConnectedSeconds() {
    final start = _connectionStartTime;
    if (start == null) return;
    connectedSeconds.value = DateTime.now().difference(start).inSeconds;
  }

  void pauseConnectionTimer() {
    _connectionTimer?.cancel();
    _connectionTimer = null;
  }

  void resumeConnectionTimer() {
    if (_isDisposed) return;
    if (isVpnConnected.value && _connectionStartTime != null) {
      _startConnectionTicker();
    }
  }

  final ValueNotifier<String> uploadSpeed = ValueNotifier<String>('0.0 KB/s');
  final ValueNotifier<String> downloadSpeed = ValueNotifier<String>('0.0 KB/s');

  final ValueNotifier<int> uploadSpeedBytes = ValueNotifier<int>(0);
  final ValueNotifier<int> downloadSpeedBytes = ValueNotifier<int>(0);

  StreamSubscription? _trafficSubscription;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  http.Client? _statsClient;
  http.Client? _apiClient;
  int _statsSessionId = 0;

  bool _isDisposed = false;

  http.Client get apiClient => _apiClient ??= _AuthClient(http.Client());

  void _closeApiClient() {
    _apiClient?.close();
    _apiClient = null;
  }

  int _ipFetchId = 0;

  Future<void> _refreshActiveSourceType(String configPath) async {
    try {
      final String lower = configPath.toLowerCase();
      final String metaPath = lower.endsWith('.yaml')
          ? '${configPath.substring(0, configPath.length - 5)}.json'
          : '$configPath.json';
      final File metaFile = File(metaPath);
      if (await metaFile.exists()) {
        final decoded = jsonDecode(await metaFile.readAsString());
        if (decoded is Map && decoded['source_type'] != null) {
          final String t = decoded['source_type'].toString();
          if (!_isDisposed) {
            activeSourceType.value = (t == 'raw') ? 'raw' : 'clash';
          }
          return;
        }
      }
    } catch (_) {}
    if (!_isDisposed) activeSourceType.value = 'clash';
  }

  // ─── Получение внешнего IP ───

  /// Получает текущий внешний IP. При активном VPN запрос идёт через прокси-
  /// порт ядра; использует идентификатор запроса, чтобы устаревшие ответы не
  /// перезаписывали более свежие.
  Future<void> fetchCurrentIp() async {
    if (_isDisposed) return;
    final int currentId = ++_ipFetchId;
    final s = SettingsService();
    try {
      if (currentIp.value == '...' || currentIp.value == 'Unknown IP') {
        currentIp.value = s.tr(
          'Получение IP...',
          'Fetching IP...',
          '正在获取 IP...',
        );
      }

      final urls = ['https://api.ipify.org', 'https://icanhazip.com'];
      String? fetchedIp;

      final bool useProxy = isVpnConnected.value && isRunning.value;
      final HttpClient httpClient = HttpClient();
      if (useProxy) {
        // Определяем порт прокси из активного конфига («mixed-port» или
        // запасной «port»). По умолчанию 7893 — это mixed-port, который мы
        // всегда записываем в генерируемые конфиги, поэтому проверка IP идёт
        // через правильный порт даже если строку порта не удалось разобрать.
        int proxyPort = 7893;
        try {
          if (_currentConfigPath != null) {
            final cfgFile = File(_currentConfigPath!);
            if (await cfgFile.exists()) {
              final lines = await cfgFile.readAsLines();
              for (final line in lines) {
                final trimmed = line.trim();
                final mp = RegExp(
                  '^mixed-port\\s*:\\s*(\\d+)',
                  caseSensitive: false,
                ).firstMatch(trimmed);
                if (mp != null) {
                  proxyPort = int.parse(mp.group(1)!);
                  break;
                }
                final p = RegExp(
                  '^port\\s*:\\s*(\\d+)',
                  caseSensitive: false,
                ).firstMatch(trimmed);
                if (p != null) {
                  proxyPort = int.parse(p.group(1)!);
                  break;
                }
              }
            }
          }
        } catch (_) {}
        httpClient.findProxy = (uri) => "PROXY 127.0.0.1:$proxyPort";
        httpClient.connectionTimeout = const Duration(seconds: 4);
      } else {
        httpClient.connectionTimeout = const Duration(seconds: 4);
      }
      final ioClient = IOClient(httpClient);

      try {
        for (int attempt = 0; attempt < 2; attempt++) {
          if (currentId != _ipFetchId || _isDisposed) {
            return;
          }
          for (final url in urls) {
            if (currentId != _ipFetchId || _isDisposed) {
              return;
            }
            try {
              final res = await ioClient
                  .get(Uri.parse(url))
                  .timeout(const Duration(seconds: 4));
              if (res.statusCode == 200 && res.body.trim().isNotEmpty) {
                fetchedIp = res.body.trim();
                break;
              }
            } catch (_) {}
          }
          if (fetchedIp != null) break;
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 1500));
          }
        }

        if (currentId != _ipFetchId || _isDisposed) return;

        if (fetchedIp != null) {
          currentIp.value = fetchedIp;
        } else {
          currentIp.value = 'Unknown IP';
        }
      } finally {
        ioClient.close();
      }
    } catch (_) {
      if (currentId != _ipFetchId || _isDisposed) return;
      currentIp.value = 'Unknown IP';
    }
  }

  // ─── Извлечение ядра и пути ───

  Future<String> _getWorkingCorePath() async {
    final directory = await getApplicationSupportDirectory();
    final String targetDir = p.join(directory.path, 'bin');
    await Directory(targetDir).create(recursive: true);
    return p.join(targetDir, 'JustClashCore.exe');
  }

  Future<String> getAbsoluteCorePath() async {
    return await _getWorkingCorePath();
  }

  Future<String> getAbsoluteGeoDbPath() async {
    final dir = await getCurrentConfigDir();
    return p.join(dir, 'geoip.dat');
  }

  /// Запрашивает версию ЗАПУЩЕННОГО ядра через его REST API (`GET /version`).
  /// Это авторитетный источник версии, когда ядро работает: не требует запуска
  /// отдельного процесса (`-v`) и не зависит от состояния файловой системы при
  /// холодном старте. Возвращает строку версии (например «v1.19.27») либо null,
  /// если ядро не запущено или API недоступно.
  Future<String?> fetchCoreVersionFromApi() async {
    if (!isRunning.value || _isDisposed) return null;
    try {
      final url = await _getControllerUrl(path: '/version');
      final response = await apiClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['version'] != null) {
          final String v = decoded['version'].toString().trim();
          if (v.isNotEmpty) return v;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> ensureCoreExists() async {
    try {
      await _coreExtractMutex.protect(
        (_) => _ensureCoreExistsInternal(),
        timeout: const Duration(seconds: 60),
      );
    } catch (e) {
      debugPrint('Ошибка ожидания извлечения ядра: $e');
    }
  }

  Future<void> _ensureCoreExistsInternal() async {
    try {
      final String targetPath = await _getWorkingCorePath();
      final File targetFile = File(targetPath);

      if (!await targetFile.exists() ||
          await targetFile.length() < 1024 * 1024) {
        final byteData = await rootBundle.load(
          'assets/core/mihomo-windows-amd64.exe',
        );
        final tempFile = File('$targetPath.tmp');

        await tempFile.writeAsBytes(
          byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          ),
          flush: true,
        );

        if (await targetFile.exists()) {
          await targetFile.delete();
        }
        await tempFile.rename(targetPath);
      }
    } catch (e, stack) {
      debugPrint('Ошибка извлечения встроенного ядра: $e\n$stack');
    }
  }

  Future<void> _extractCoreIfNeeded() async {
    await ensureCoreExists();
  }

  Future<String> getCurrentConfigDir() async {
    final directory = await getApplicationSupportDirectory();
    return directory.path;
  }

  Future<void> _killOldProcessByPid() async {
    int? oldPid;
    try {
      final dir = await getCurrentConfigDir();
      final pidFile = File(p.join(dir, 'mihomo.pid'));
      if (await pidFile.exists()) {
        oldPid = int.tryParse((await pidFile.readAsString()).trim());
        await pidFile.delete();
      }
    } catch (e) {
      debugPrint('Ошибка при очистке старого процесса по PID: $e');
    }

    // Завершаем ТОЛЬКО записанный процесс ядра (всё его дерево), а не каждый
    // JustClashCore.exe по имени образа — чтобы второй запущенный экземпляр
    // приложения никогда не убивал ядро другого экземпляра. К завершению по
    // имени образа прибегаем только когда PID не записан (осиротевшее ядро
    // после сбоя).
    try {
      if (oldPid != null) {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/F', '/PID', '$oldPid', '/T']);
        } else {
          Process.killPid(oldPid);
        }
      } else if (Platform.isWindows) {
        await Process.run('taskkill', [
          '/F',
          '/IM',
          'JustClashCore.exe',
          '/T',
        ]);
      }
    } catch (_) {}
  }

  // ─── Гео-базы (извлечение из ассетов и загрузка с GitHub) ───

  static const Map<String, String> _geoAssets = {
    'geoip.dat': 'assets/core/geoip.dat',
    'geosite.dat': 'assets/core/geosite.dat',
    'geoip.metadb': 'assets/core/geoip.metadb',
    'GeoLite2-ASN.mmdb': 'assets/core/GeoLite2-ASN.mmdb',
  };

  static const Map<String, String> _geoDownloadUrls = {
    'geoip.dat':
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat',
    'geosite.dat':
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
    'geoip.metadb':
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb',
    'GeoLite2-ASN.mmdb':
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb',
  };

  Future<bool> ensureGeoDatabase(
    String targetDir, {
    bool forceUpdate = false,
  }) =>
      _geoMutex.protect(
        (isCancelled) =>
            _ensureGeoDatabaseInternal(targetDir, forceUpdate, isCancelled),
        // Бюджет на ВЕСЬ проход обновления гео-баз (4 файла подряд), а не на
        // один файл. Прежние 120 c были общим лимитом критической секции: на
        // небыстром канале первые три файла «съедали» почти весь лимит, и флаг
        // отмены мьютекса срабатывал на последнем файле (GeoLite2-ASN.mmdb) —
        // он переставал докачиваться. Даём щедрые 10 минут на весь набор;
        // каждый отдельный файл по-прежнему защищён своими таймаутами (60 c на
        // старт ответа и 120 c на простой между чанками), поэтому реально
        // зависшая загрузка прервётся по файлу, а не повиснет на весь лимит.
        timeout: const Duration(minutes: 10),
      );

  Future<bool> _ensureGeoDatabaseInternal(
    String targetDir,
    bool forceUpdate,
    bool Function() isCancelled,
  ) async {
    if (_isDisposed) return false;

    try {
      await Directory(targetDir).create(recursive: true);

      bool allOk = true;

      int fileIndex = 0;
      final int totalFiles = _geoAssets.length;
      for (final fileName in _geoAssets.keys) {
        if (isCancelled() || _isDisposed) break;
        fileIndex++;
        final file = File(p.join(targetDir, fileName));

        if (!forceUpdate && await file.exists() && await file.length() > 1024) {
          continue;
        }

        if (forceUpdate) {
          final bool downloaded = await _downloadGeoFile(
            fileName,
            file,
            isCancelled,
            fileIndex,
            totalFiles,
          );
          if (downloaded) continue;
          if (await file.exists() && await file.length() > 1024) continue;
        }

        try {
          final byteData = await rootBundle.load(_geoAssets[fileName]!);
          final tempFile = File('${file.path}.tmp');
          await tempFile.writeAsBytes(
            byteData.buffer.asUint8List(
              byteData.offsetInBytes,
              byteData.lengthInBytes,
            ),
            flush: true,
          );
          if (await file.exists()) await file.delete();
          await tempFile.rename(file.path);
        } catch (e) {
          debugPrint('Не удалось извлечь гео-файл $fileName из ассетов: $e');
          allOk = false;
        }
      }

      return allOk;
    } catch (e, stack) {
      debugPrint('Критическая ошибка в ensureGeoDatabase: $e\n$stack');
    } finally {
      geoProgress.value = null;
    }
    return false;
  }

  Future<bool> _downloadGeoFile(
    String fileName,
    File target,
    bool Function() isCancelled,
    int fileIndex,
    int totalFiles,
  ) async {
    final String? url = _geoDownloadUrls[fileName];
    if (url == null) return false;

    final tempFile = File('${target.path}.tmp');
    final http.Client client = http.Client();
    IOSink? sink;
    try {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      if (isCancelled() || _isDisposed) return false;

      geoProgress.value = GeoUpdateProgress(
        fileName: fileName,
        fileIndex: fileIndex,
        totalFiles: totalFiles,
        received: 0,
        total: -1,
        speedBytesPerSec: 0,
      );

      final request = http.Request('GET', Uri.parse(url));
      request.headers['Accept'] = '*/*';
      final http.StreamedResponse response =
          await client.send(request).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        return false;
      }

      final int totalBytes = response.contentLength ?? -1;
      int received = 0;
      double speed = 0;
      int lastEmitMs = 0;
      int lastEmitBytes = 0;
      final stopwatch = Stopwatch()..start();

      sink = tempFile.openWrite();

      // Щедрый таймаут на каждый чанк: загрузки релизов GitHub идут через
      // CDN-узлы, которые на медленных соединениях могут зависать между
      // чанками. 120с на чанк совпадают с общим таймаутом мьютекса, чтобы
      // медленную, но идущую загрузку никогда не обрывало посреди файла.
      await for (final List<int> chunk in response.stream.timeout(
        const Duration(seconds: 120),
      )) {
        if (isCancelled() || _isDisposed) {
          await sink!.close();
          sink = null;
          try {
            if (await tempFile.exists()) await tempFile.delete();
          } catch (_) {}
          return false;
        }
        sink!.add(chunk);
        received += chunk.length;

        final int elapsedMs = stopwatch.elapsedMilliseconds;
        if (elapsedMs - lastEmitMs >= 200) {
          final int deltaMs = elapsedMs - lastEmitMs;
          final int deltaBytes = received - lastEmitBytes;
          if (deltaMs > 0) speed = deltaBytes * 1000 / deltaMs;
          lastEmitMs = elapsedMs;
          lastEmitBytes = received;
          geoProgress.value = GeoUpdateProgress(
            fileName: fileName,
            fileIndex: fileIndex,
            totalFiles: totalFiles,
            received: received,
            total: totalBytes,
            speedBytesPerSec: speed,
          );
        }
      }

      await sink!.flush();
      await sink.close();
      sink = null;

      geoProgress.value = GeoUpdateProgress(
        fileName: fileName,
        fileIndex: fileIndex,
        totalFiles: totalFiles,
        received: received,
        total: totalBytes < 0 ? received : totalBytes,
        speedBytesPerSec: speed,
      );

      if (received > 1024) {
        if (await target.exists()) await target.delete();
        await tempFile.rename(target.path);
        return true;
      }
    } catch (e) {
      debugPrint('Не удалось загрузить гео-файл $fileName из $url: $e');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }

    if (await tempFile.exists()) {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
    return false;
  }

  /// Приводит разобранное значение external-controller к адресу, реально
  /// достижимому как клиент. Голый «:9090» или адрес-маска привязки
  /// («0.0.0.0» / «[::]») не годятся как цель клиента, поэтому сохраняем порт,
  /// но принудительно ставим loopback-хост. Пустой ввод даёт значение по
  /// умолчанию.
  static String _normalizeControllerAddr(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) return '127.0.0.1:9090';
    if (value.startsWith(':')) return '127.0.0.1$value';
    if (value.startsWith('0.0.0.0:')) {
      return '127.0.0.1${value.substring('0.0.0.0'.length)}';
    }
    if (value.startsWith('[::]:')) {
      return '127.0.0.1${value.substring('[::]'.length)}';
    }
    return value;
  }

  Future<void> _updateCachedControllerAddr(String configPath) async {
    try {
      final file = File(configPath);
      if (await file.exists()) {
        final lines = await file.readAsLines();
        final regExp = RegExp(
          '^external-controller\\s*:\\s*["\']?([^#"\']+)["\']?',
          caseSensitive: false,
        );
        for (final line in lines) {
          final trimmed = line.trim();
          final match = regExp.firstMatch(trimmed);
          if (match != null) {
            String value = match.group(1)!.trim();
            if (value.isNotEmpty) {
              _cachedControllerAddr = _normalizeControllerAddr(value);
              break;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Не удалось распарсить адрес контроллера из конфига: $e');
    }
  }

  Future<String> _getControllerUrl({String path = ''}) async {
    return 'http://$_cachedControllerAddr$path';
  }

  // ─── Запуск, горячая перезагрузка и остановка ядра ───

  Future<bool> startCore(String configPath) => _mutex.protect(
        (isCancelled) => _startCoreInternal(configPath, isCancelled),
        timeout: const Duration(seconds: 45),
      );

  Future<bool> _startCoreInternal(
    String configPath,
    bool Function() isCancelled,
  ) async {
    try {
      if (_isDisposed) return false;

      if (isRunning.value) {
        await _stopCoreInternal();
      }

      await _killOldProcessByPid();
      await Future.delayed(const Duration(milliseconds: 600));

      if (isCancelled() || _isDisposed) return false;

      final configFile = File(configPath);
      if (!await configFile.exists()) {
        debugPrint('Файл конфигурации отсутствует по пути: $configPath');
        return false;
      }

      final String configDir = await getCurrentConfigDir();
      await ensureGeoDatabase(configDir);

      if (isCancelled() || _isDisposed) return false;

      await _extractCoreIfNeeded();

      if (isCancelled() || _isDisposed) return false;

      _currentConfigPath = configPath;
      await _updateCachedControllerAddr(configPath);
      await _refreshActiveSourceType(configPath);

      final String coreExecutable = await _getWorkingCorePath();

      _process = await Process.start(coreExecutable, [
        '-f',
        configPath,
        '-d',
        configDir,
      ]);

      if (_isDisposed) {
        _process?.kill();
        _process = null;
        return false;
      }

      isRunning.value = true;

      final pidFile = File(p.join(configDir, 'mihomo.pid'));
      await pidFile.writeAsString(_process!.pid.toString(), flush: true);

      _stdoutSubscription = _process!.stdout.listen(
        (_) {},
        onError: (e) => debugPrint('STDOUT Error: $e'),
        cancelOnError: true,
      );
      _stderrSubscription = _process!.stderr.listen(
        (_) {},
        onError: (e) => debugPrint('STDERR Error: $e'),
        cancelOnError: true,
      );

      _process!.exitCode.then((code) {
        debugPrint('Процесс Mihomo завершился с кодом: $code');
        if (!_isDisposed && isRunning.value) {
          isRunning.value = false;
          isVpnConnected.value = false;
          stopCore().catchError((e) {
            debugPrint('Ошибка фоновой остановки ядра: $e');
          });
        }
      });

      bool apiReady = false;
      for (int i = 0; i < 30; i++) {
        if (!isRunning.value || isCancelled() || _isDisposed) break;
        try {
          final url = await _getControllerUrl(path: '/');
          final res = await apiClient
              .get(Uri.parse(url))
              .timeout(const Duration(milliseconds: 500));
          if (res.statusCode == 200) {
            apiReady = true;
            break;
          }
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (!apiReady || !isRunning.value || isCancelled() || _isDisposed) {
        debugPrint(
          'Ядро не запустилось, API недоступно или процесс отменен по таймауту.',
        );
        await _stopCoreInternal();
        return false;
      }

      await setVpnMode('Direct');

      if (_isDisposed) return false;

      await _restoreGroupSelections();

      if (_isDisposed) return false;

      startStatsTracking();

      configVersion.value++;
      return true;
    } catch (e, stack) {
      debugPrint('Критическая ошибка запуска ядра: $e\n$stack');
      await _stopCoreInternal();
      return false;
    }
  }

  Future<bool> hotReloadConfig(String configPath) => _mutex.protect(
        (isCancelled) => _hotReloadConfigInternal(configPath, isCancelled),
        timeout: const Duration(seconds: 45),
      );

  Future<bool> _hotReloadConfigInternal(
    String configPath,
    bool Function() isCancelled,
  ) async {
    if (_isDisposed) return false;
    if (!isRunning.value) {
      _currentConfigPath = configPath;
      return await _startCoreInternal(configPath, isCancelled);
    }
    // Запоминаем, был ли туннель поднят ДО перезагрузки: если мягкая
    // перезагрузка PUT /configs не удастся и мы откатимся к полному
    // перезапуску ядра, то сможем вернуть туннель в то же состояние, а не
    // молча сбросить его в Direct. Так же ведут себя clash-verge / FlClash —
    // обновление профиля никогда не разрывает VPN.
    final bool wasConnectedBeforeReload = isVpnConnected.value;
    try {
      String targetAddr = _cachedControllerAddr;
      try {
        final file = File(configPath);
        if (await file.exists()) {
          final lines = await file.readAsLines();
          final regExp = RegExp(
            '^external-controller\\s*:\\s*["\']?([^#"\']+)["\']?',
            caseSensitive: false,
          );
          for (final line in lines) {
            final trimmed = line.trim();
            final match = regExp.firstMatch(trimmed);
            if (match != null) {
              String value = match.group(1)!.trim();
              if (value.isNotEmpty) {
                targetAddr = _normalizeControllerAddr(value);
                break;
              }
            }
          }
        }
      } catch (_) {}

      if (_isDisposed || isCancelled()) return false;

      final url = 'http://$targetAddr/configs';
      final response = await apiClient
          .put(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({'path': configPath}),
          )
          .timeout(const Duration(seconds: 30));

      if (_isDisposed || isCancelled()) return false;

      if (response.statusCode == 204) {
        // Сохраняем активный туннель пользователя при ЛЮБОЙ успешной горячей
        // перезагрузке конфига, включая переключение на ДРУГОЙ профиль. Так же
        // ведёт себя clash-verge / FlClashX: смена профиля никогда не сбрасывает
        // VPN молча — туннель остаётся поднятым, а сохранённый выбор узлов по
        // группам нового профиля восстанавливается сразу после.
        final bool wasConnected = isVpnConnected.value;
        _cachedControllerAddr = targetAddr;
        _currentConfigPath = configPath;
        await _refreshActiveSourceType(configPath);
        await setVpnMode(wasConnected ? 'Rule' : 'Direct');

        if (_isDisposed || isCancelled()) return false;

        await _restoreGroupSelections();

        if (_isDisposed || isCancelled()) return false;

        configVersion.value++;
        return true;
      }
    } catch (e) {
      debugPrint(
        'Мягкий перезапуск конфигурации не удался, выполняем полный перезапуск ядра: $e',
      );
    }

    if (_isDisposed || isCancelled()) return false;
    _currentConfigPath = configPath;
    final bool restarted = await _startCoreInternal(configPath, isCancelled);
    if (restarted &&
        wasConnectedBeforeReload &&
        !_isDisposed &&
        !isCancelled()) {
      // Мягкая перезагрузка откатилась к полному перезапуску, который всегда
      // поднимается в Direct. Повторно поднимаем туннель в то состояние, что
      // было до перезагрузки.
      await setVpnMode('Rule');
    }
    return restarted;
  }

  Future<void> _stopCoreInternal() async {
    stopStatsTracking();
    _closeApiClient();

    if (!_isDisposed) {
      isRunning.value = false;
      isVpnConnected.value = false;
      activeSourceType.value = 'none';
    }

    _stdoutSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription?.cancel();
    _stderrSubscription = null;

    if (_process != null) {
      try {
        _process!.kill();
      } catch (_) {}
      _process = null;
    }

    await _killOldProcessByPid();

    if (!_isDisposed) {
      uploadSpeed.value = '0.0 KB/s';
      downloadSpeed.value = '0.0 KB/s';
      uploadSpeedBytes.value = 0;
      downloadSpeedBytes.value = 0;
    }
  }

  Future<void> stopCore() {
    if (!_isDisposed) {
      isRunning.value = false;
      isVpnConnected.value = false;
    }
    return _mutex.protect((isCancelled) => _stopCoreInternal());
  }

  Future<void> killCoreImmediately() async {
    if (!_isDisposed) {
      isRunning.value = false;
      isVpnConnected.value = false;
    }

    try {
      _process?.kill();
    } catch (_) {}
    _process = null;

    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/F', '/IM', 'JustClashCore.exe', '/T']);
      } catch (_) {}
    } else {
      try {
        final dir = await getCurrentConfigDir();
        final pidFile = File(p.join(dir, 'mihomo.pid'));
        if (await pidFile.exists()) {
          final oldPid = int.tryParse((await pidFile.readAsString()).trim());
          if (oldPid != null) {
            Process.killPid(oldPid, ProcessSignal.sigkill);
          }
        }
      } catch (_) {}
    }
  }

  // ─── Режим VPN (TUN) ───

  /// Переключает режим ядра: rule (TUN вкл., трафик через VPN) или direct
  /// (TUN выкл.). Делает до 5 попыток PATCH, затем проверяет фактическое
  /// состояние через GET.
  Future<bool> setVpnMode(String mode) async {
    if (!isRunning.value) return false;
    final String formalMode =
        (mode.toLowerCase() == 'rule') ? 'rule' : 'direct';
    final bool enableTun = formalMode == 'rule';

    if (!_isDisposed) isToggling.value = true;
    try {
      int retries = 5;
      while (retries > 0) {
        try {
          final url = await _getControllerUrl(path: '/configs');
          final response = await apiClient
              .patch(
                Uri.parse(url),
                headers: {'Content-Type': 'application/json; charset=utf-8'},
                body: jsonEncode({
                  'mode': formalMode,
                  'tun': {'enable': enableTun},
                }),
              )
              .timeout(const Duration(seconds: 8));

          if (response.statusCode == 204) {
            isVpnConnected.value = enableTun;
            if (!enableTun) {
              uploadSpeed.value = '0.0 KB/s';
              downloadSpeed.value = '0.0 KB/s';
              uploadSpeedBytes.value = 0;
              downloadSpeedBytes.value = 0;
            }
            fetchCurrentIp();
            return true;
          }
        } catch (e) {
          debugPrint(
            'Не удалось переключить режим TUN (попытка ${6 - retries}): $e',
          );
          if (retries > 1) {
            await Future.delayed(const Duration(milliseconds: 800));
          }
        }
        retries--;
      }

      try {
        final url = await _getControllerUrl(path: '/configs');
        final response = await apiClient
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            final currentMode = decoded['mode']?.toString().toLowerCase();
            final tunEnabled = decoded['tun']?['enable'] == true;
            if (currentMode == formalMode && tunEnabled == enableTun) {
              isVpnConnected.value = enableTun;
              fetchCurrentIp();
              return true;
            }
          }
        }
      } catch (_) {}

      return false;
    } finally {
      if (!_isDisposed) isToggling.value = false;
    }
  }

  // ─── Статистика трафика и скорость ───

  void startStatsTracking() async {
    if (!isRunning.value) return;

    _trafficSubscription?.cancel();
    _trafficSubscription = null;
    _statsClient?.close();
    _statsClient = null;

    _ipTimer?.cancel();
    if (isVpnConnected.value && currentIp.value == '...') {
      fetchCurrentIp();
    }
    _ipTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (isVpnConnected.value) fetchCurrentIp();
    });

    final int currentSession = ++_statsSessionId;

    int retries = 5;
    while (retries > 0 && currentSession == _statsSessionId) {
      final client = _AuthClient(http.Client());
      try {
        _statsClient = client;

        final url = await _getControllerUrl(path: '/traffic');
        final request = http.Request('GET', Uri.parse(url));
        final http.StreamedResponse response =
            await client.send(request).timeout(const Duration(seconds: 5));

        if (currentSession != _statsSessionId) {
          client.close();
          return;
        }

        bool retryScheduled = false;
        void scheduleRetry() {
          if (currentSession == _statsSessionId &&
              !retryScheduled &&
              !_isDisposed) {
            retryScheduled = true;
            Future.delayed(const Duration(seconds: 2), () {
              if (currentSession == _statsSessionId && !_isDisposed) {
                startStatsTracking();
              }
            });
          }
        }

        _trafficSubscription = response.stream
            .transform(utf8.decoder)
            .handleError((_) => scheduleRetry())
            .transform(const LineSplitter())
            .listen(
          (String line) {
            if (currentSession != _statsSessionId || _isDisposed) return;
            if (line.trim().isNotEmpty) {
              try {
                final decoded = jsonDecode(line);
                if (decoded is Map) {
                  final int downRaw = (decoded['down'] as num?)?.toInt() ?? 0;
                  final int upRaw = (decoded['up'] as num?)?.toInt() ?? 0;

                  downloadSpeedBytes.value = downRaw;
                  uploadSpeedBytes.value = upRaw;

                  downloadSpeed.value = _formatSpeed(downRaw);
                  uploadSpeed.value = _formatSpeed(upRaw);
                }
              } catch (_) {}
            }
          },
          onError: (_) => scheduleRetry(),
          onDone: () => scheduleRetry(),
        );
        return;
      } catch (_) {
        if (_statsClient == client) {
          _statsClient?.close();
          _statsClient = null;
        } else {
          client.close();
        }
        retries--;
        if (retries > 0 && currentSession == _statsSessionId) {
          await Future.delayed(const Duration(seconds: 1));
        } else if (currentSession == _statsSessionId) {
          stopStatsTracking();
        }
      }
    }
  }

  String _formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '$bytesPerSecond B/s';
    }
    double kb = bytesPerSecond / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB/s';
    }
    double mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB/s';
  }

  void stopStatsTracking() {
    _statsSessionId++;
    _ipTimer?.cancel();
    _ipTimer = null;
    _trafficSubscription?.cancel();
    _trafficSubscription = null;
    _statsClient?.close();
    _statsClient = null;
  }

  // ─── Переключение узлов и измерение пинга ───

  Future<bool> switchProxy(String baseGroup, String proxyName) async {
    if (!isRunning.value || proxyName.isEmpty) return false;
    try {
      final proxiesUrl = await _getControllerUrl(path: '/proxies');
      final responseGet = await apiClient
          .get(Uri.parse(proxiesUrl))
          .timeout(const Duration(seconds: 5));
      if (responseGet.statusCode == 200) {
        final decoded = jsonDecode(responseGet.body);
        if (decoded is Map) {
          final proxiesData = decoded['proxies'];
          if (proxiesData is Map) {
            bool anySuccess = false;

            final List<String> groupNames = [
              baseGroup,
              for (final k in proxiesData.keys)
                if (k.toString() != baseGroup) k.toString(),
            ];

            for (final groupName in groupNames) {
              final group = proxiesData[groupName];
              if (group is! Map) continue;
              if ((group['type'] ?? '').toString() != 'Selector') continue;
              final allList = group['all'] as List?;
              if (allList == null || !allList.contains(proxyName)) continue;
              if ((group['now'] ?? '').toString() == proxyName) {
                anySuccess = true;
                continue;
              }
              try {
                final putUrl = await _getControllerUrl(
                  path: '/proxies/${Uri.encodeComponent(groupName)}',
                );
                final putRes = await apiClient
                    .put(
                      Uri.parse(putUrl),
                      headers: {
                        'Content-Type': 'application/json; charset=utf-8',
                      },
                      body: jsonEncode({'name': proxyName}),
                    )
                    .timeout(const Duration(seconds: 3));
                if (putRes.statusCode == 204) {
                  anySuccess = true;
                  final String? pk = _profileKey;
                  if (pk != null) {
                    SettingsService().setGroupSelection(
                      pk,
                      groupName,
                      proxyName,
                    );
                  }
                }
              } catch (_) {}
            }

            if (anySuccess) {
              SettingsService().lastSelectedProxy = proxyName;
              await SettingsService().saveSettings();

              try {
                final connectionsUrl = await _getControllerUrl(
                  path: '/connections',
                );
                await apiClient
                    .delete(Uri.parse(connectionsUrl))
                    .timeout(const Duration(seconds: 2));
              } catch (_) {}

              currentIp.value = '...';
              Future.delayed(
                const Duration(milliseconds: 1500),
                fetchCurrentIp,
              );
            }

            return anySuccess;
          }
        }
      }
    } catch (e) {
      debugPrint('Ошибка при переключении прокси: $e');
    }
    return false;
  }

  http.Client? _pingClient;

  void abortActivePingRequests() {
    try {
      _pingClient?.close();
      _pingClient = null;
    } catch (_) {}
  }

  Future<String> _measureTcpPing(String host, int port) async {
    if (host.isEmpty || port <= 0) return 'timeout';
    final stopwatch = Stopwatch()..start();
    try {
      final cleanHost = host.replaceAll('[', '').replaceAll(']', '');
      final socket = await Socket.connect(
        cleanHost,
        port,
        timeout: const Duration(milliseconds: 2500),
      );
      stopwatch.stop();
      try {
        socket.destroy();
      } catch (_) {}
      return '${stopwatch.elapsedMilliseconds} ms';
    } catch (_) {}
    return 'timeout';
  }

  bool get _tcpPingAllowed =>
      SettingsService().pingMethod == 'tcp' && activeSourceType.value == 'raw';

  /// Активен ли пер-узловой TCP-пинг для текущего профиля (raw + tcp).
  bool get tcpPingActive => _tcpPingAllowed;

  Future<String> getProxyDelay(
    String proxyName, {
    String? host,
    int? port,
  }) async {
    if (_tcpPingAllowed &&
        host != null &&
        host.isNotEmpty &&
        port != null &&
        port > 0) {
      return await _measureTcpPing(host, port);
    }
    if (!isRunning.value || _isDisposed) return 'timeout';
    try {
      final url = await _getControllerUrl(
        path:
            '/proxies/${Uri.encodeComponent(proxyName)}/delay?timeout=3000&url=http://www.gstatic.com/generate_204',
      );
      _pingClient ??= _AuthClient(http.Client());
      final response = await _pingClient!
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['delay'] != null) {
          return '${decoded['delay']} ms';
        }
      }
    } catch (_) {}
    return 'timeout';
  }

  /// Пакетный замер задержек для целой группы через эндпоинт
  /// /group/{name}/delay ядра Mihomo. Возвращает сопоставление «имя узла →
  /// задержка в мс»; неудачные и нулевые узлы пропускаются.
  Future<Map<String, String>> getGroupDelays(
    String groupName, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (!isRunning.value || _isDisposed || groupName.isEmpty) return {};
    try {
      final url = await _getControllerUrl(
        path:
            '/group/${Uri.encodeComponent(groupName)}/delay?timeout=3000&url=http://www.gstatic.com/generate_204',
      );
      _pingClient ??= _AuthClient(http.Client());
      final response = await _pingClient!.get(Uri.parse(url)).timeout(timeout);
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final Map<String, String> result = {};
          decoded.forEach((key, value) {
            final int? ms =
                (value is num) ? value.toInt() : int.tryParse('$value');
            if (ms != null && ms > 0) {
              result[key.toString()] = '$ms ms';
            }
          });
          return result;
        }
      }
    } catch (_) {}
    return {};
  }

  Future<void> pingProxiesIndividually(
    List<Map<String, dynamic>> targets, {
    required void Function(String name, String delay) onResult,
    bool Function()? isCancelled,
    int concurrency = 16,
  }) async {
    if (!isRunning.value || targets.isEmpty) return;

    int nextIndex = 0;
    final bool useTcp = _tcpPingAllowed;

    Future<void> runWorker() async {
      while (nextIndex < targets.length) {
        if (isCancelled != null && isCancelled()) break;

        final int currentIndex = nextIndex++;
        if (currentIndex >= targets.length) break;

        final target = targets[currentIndex];
        final String name = target['name'] as String;
        final String host = target['host']?.toString() ?? '';
        final int port = int.tryParse(target['port']?.toString() ?? '0') ?? 0;

        String delay;
        if (useTcp && host.isNotEmpty && port > 0) {
          delay = await _measureTcpPing(host, port);
        } else {
          delay = await getProxyDelay(name);
        }

        if (isCancelled == null || !isCancelled()) {
          onResult(name, delay);
        }
      }
    }

    final List<Future<void>> workers = List.generate(
      concurrency < targets.length ? concurrency : targets.length,
      (_) => runWorker(),
    );
    await Future.wait(workers);
  }

  // ─── Группы прокси и восстановление выбора ───

  Future<List<Map<String, dynamic>>> getProxyGroups() async {
    if (!isRunning.value) return [];

    final Map<String, Map<String, dynamic>> localProxyDetails = {};
    final List<String> groupOrder = <String>[];
    final Set<String> hiddenGroups = <String>{};
    if (_currentConfigPath != null) {
      try {
        final file = File(_currentConfigPath!);
        if (await file.exists()) {
          final content = await file.readAsString();
          final doc = loadYaml(content);
          if (doc is YamlMap && doc['proxies'] is YamlList) {
            for (final pr in doc['proxies']) {
              if (pr is YamlMap && pr['name'] != null) {
                localProxyDetails[pr['name'].toString()] = {
                  'server': pr['server']?.toString() ?? '',
                  'port': int.tryParse(pr['port']?.toString() ?? '0') ?? 0,
                };
              }
            }
          }
          if (doc is YamlMap && doc['proxy-groups'] is YamlList) {
            for (final grp in doc['proxy-groups']) {
              if (grp is YamlMap && grp['name'] != null) {
                final String gName = grp['name'].toString();
                groupOrder.add(gName);
                if (grp['hidden'] == true) {
                  hiddenGroups.add(gName);
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Ошибка парсинга локального YAML для групп: $e');
      }
    }

    try {
      final url = await _getControllerUrl(path: '/proxies');
      final response = await apiClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['proxies'] is Map) {
          final Map proxiesData = decoded['proxies'] as Map;
          final List<Map<String, dynamic>> groups = [];

          final Set<String> hiddenNames = {...hiddenGroups};
          for (final e in proxiesData.entries) {
            final v = e.value;
            if (v is Map && v['hidden'] == true) {
              hiddenNames.add(e.key.toString());
            }
          }

          for (final entry in proxiesData.entries) {
            final data = entry.value;
            if (data is! Map) continue;
            final String groupName = entry.key.toString();
            if (groupName == 'GLOBAL') continue;
            if (hiddenNames.contains(groupName)) continue;
            final String type = (data['type'] ?? '').toString();
            final allList = data['all'];
            if (allList is! List || allList.isEmpty) continue;

            final List<Map<String, dynamic>> nodes = [];
            for (final n in allList) {
              final String nodeName = n.toString();
              if (nodeName == 'GLOBAL') continue;
              final details = localProxyDetails[nodeName];
              nodes.add({
                'name': nodeName,
                'server': details?['server'] ?? '',
                'port': details?['port'] ?? 0,
              });
            }
            if (nodes.isEmpty) continue;

            groups.add({
              'name': groupName,
              'type': type,
              'now': (data['now'] ?? '').toString(),
              'icon': (data['icon'] ?? '').toString(),
              'nodes': nodes,
            });
          }

          if (groupOrder.isNotEmpty) {
            int rank(String n) {
              final int i = groupOrder.indexOf(n);
              return i < 0 ? groupOrder.length : i;
            }

            final List<MapEntry<int, Map<String, dynamic>>> indexed = [
              for (int i = 0; i < groups.length; i++) MapEntry(i, groups[i]),
            ];
            indexed.sort((a, b) {
              final int ra = rank(a.value['name'].toString());
              final int rb = rank(b.value['name'].toString());
              if (ra != rb) return ra.compareTo(rb);
              return a.key.compareTo(b.key);
            });
            groups
              ..clear()
              ..addAll(indexed.map((e) => e.value));
          }

          return groups;
        }
      }
    } catch (_) {}
    return [];
  }

  /// Восстанавливает ранее выбранный узел в КАЖДОЙ группе-селекторе активного
  /// профиля. Идемпотентно: пропускает группы, уже стоящие на сохранённом узле
  /// (их мог восстановить store-selected ядра), поэтому двойного восстановления
  /// нет. Откатывается к устаревшему единому глобальному значению только когда
  /// данных по группам ещё нет (настройки обновлены со старой версии).
  Future<void> _restoreGroupSelections() async {
    if (_isDisposed || !isRunning.value) return;
    final String? pk = _profileKey;
    if (pk == null) return;

    List<Map<String, dynamic>> groups;
    try {
      groups = await getProxyGroups();
    } catch (_) {
      return;
    }

    bool anyRestored = false;
    for (final g in groups) {
      if ((g['type'] ?? '').toString() != 'Selector') continue;
      final String gName = (g['name'] ?? '').toString();
      if (gName.isEmpty) continue;
      final String? saved = SettingsService().getGroupSelection(pk, gName);
      if (saved == null || saved.isEmpty) continue;

      final List nodes = (g['nodes'] as List?) ?? const [];
      final bool exists = nodes.any(
        (n) =>
            (n is Map ? (n['name'] ?? '').toString() : n.toString()) == saved,
      );
      if (!exists) continue;

      anyRestored = true;
      if ((g['now'] ?? '').toString() == saved) continue;
      try {
        final putUrl = await _getControllerUrl(
          path: '/proxies/${Uri.encodeComponent(gName)}',
        );
        await apiClient
            .put(
              Uri.parse(putUrl),
              headers: {'Content-Type': 'application/json; charset=utf-8'},
              body: jsonEncode({'name': saved}),
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }

    if (!anyRestored) {
      final String legacy = SettingsService().lastSelectedProxy;
      if (legacy.isNotEmpty) {
        await switchProxy('PROXY', legacy);
      }
    }
  }

  Future<bool> selectInGroup(String groupName, String proxyName) async {
    if (!isRunning.value) return false;
    try {
      final putUrl = await _getControllerUrl(
        path: '/proxies/${Uri.encodeComponent(groupName)}',
      );
      final putRes = await apiClient
          .put(
            Uri.parse(putUrl),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({'name': proxyName}),
          )
          .timeout(const Duration(seconds: 3));

      if (putRes.statusCode == 204) {
        final String? pk = _profileKey;
        if (pk != null) {
          SettingsService().setGroupSelection(pk, groupName, proxyName);
        }
        SettingsService().lastSelectedProxy = proxyName;
        await SettingsService().saveSettings();
        try {
          final connectionsUrl = await _getControllerUrl(path: '/connections');
          await apiClient
              .delete(Uri.parse(connectionsUrl))
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
        currentIp.value = '...';
        Future.delayed(const Duration(milliseconds: 1500), fetchCurrentIp);
        return true;
      }
    } catch (e) {
      debugPrint('Ошибка выбора узла в группе $groupName: $e');
    }
    return false;
  }

  // ─── Освобождение ресурсов ───

  /// Останавливает ядро, отменяет таймеры/подписки и освобождает все
  /// ValueNotifier. После вызова контроллер больше не используется.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _connectionTimer?.cancel();
    _ipTimer?.cancel();

    if (_process != null) {
      try {
        _process!.kill();
      } catch (_) {}
      _process = null;
    }

    abortActivePingRequests();
    await stopCore();
    _closeApiClient();

    isRunning.dispose();
    isVpnConnected.dispose();
    isToggling.dispose();
    configVersion.dispose();
    activeSourceType.dispose();
    uploadSpeed.dispose();
    downloadSpeed.dispose();
    uploadSpeedBytes.dispose();
    downloadSpeedBytes.dispose();
    connectedSeconds.dispose();
    currentIp.dispose();
    geoProgress.dispose();
    isRefreshingSubscriptions.dispose();
    refreshingProfileFile.dispose();
  }
}
