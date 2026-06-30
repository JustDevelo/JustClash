// ═══════════════════════════════════════════════════════════════════════════
// ProxiesScreen — экран выбора прокси-узла.
//
// Назначение файла:
//   • Отображение групп прокси и их узлов (сетка/список) с поиском и сортировкой.
//   • Тест задержки (TCP-пинг для raw либо delay-проба ядра) по группам и узлам.
//   • Определение страны узла по имени и отрисовка флага; кэш иконок групп на диске.
// Экран реактивный: подписан на configVersion, isRunning и activeSourceType ядра.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart' hide ProxyElement;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/core_controller.dart';
import '../services/settings_service.dart';
import '../models/proxy_element.dart';

/// Экран «Прокси»: список групп и узлов активного профиля.
class ProxiesScreen extends StatefulWidget {
  final CoreController coreController;
  const ProxiesScreen({super.key, required this.coreController});

  @override
  State<ProxiesScreen> createState() => _ProxiesScreenState();
}

/// Состояние экрана «Прокси»: загрузка групп, поиск, сортировка и тесты задержки.
class _ProxiesScreenState extends State<ProxiesScreen>
    with SingleTickerProviderStateMixin {
  // ─── Поля состояния ───

  final TextEditingController _searchController = TextEditingController();
  final List<_ProxyGroup> _groups = [];
  String _searchQuery = '';
  bool _isLoading = false;
  bool _showSearch = false;
  String _currentSort = 'default';
  final Set<String> _collapsedGroups = <String>{};
  // Группы, которые пользователь развернул вручную; сохраняются между
  // перезагрузками в рамках сессии, чтобы авто-сворачивание при обновлении не
  // сворачивало то, что пользователь открыл. Не персистится — каждый новый
  // запуск приложения начинается полностью свёрнутым.
  final Set<String> _userExpanded = <String>{};

  int _latencyTestSessionId = 0;
  bool _isTestingLatency = false;
  int _loadingGeneration = 0;

  late final AnimationController _refreshSpin;

  @override
  void initState() {
    super.initState();
    _refreshSpin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    widget.coreController.configVersion.addListener(_loadGroups);
    _loadGroups();
  }

  @override
  void dispose() {
    widget.coreController.abortActivePingRequests();
    widget.coreController.configVersion.removeListener(_loadGroups);
    _refreshSpin.dispose();
    _searchController.dispose();

    for (final g in _groups) {
      for (final p in g.nodes) {
        p.dispose();
      }
    }
    super.dispose();
  }

  // ─── Загрузка групп прокси ───

  /// Загружает группы прокси из ядра с повторами (узлы REJECT отфильтровываются).
  /// Каждый вызов помечается номером поколения, чтобы устаревшая загрузка не
  /// перезаписала результат более новой. Для Clash-профилей группы стартуют
  /// свёрнутыми, для raw — единственная группа всегда развёрнута.
  Future<void> _loadGroups() async {
    final int myGeneration = ++_loadingGeneration;
    final Stopwatch loadStopwatch = Stopwatch()..start();

    _latencyTestSessionId++;
    _isTestingLatency = false;
    widget.coreController.abortActivePingRequests();

    if (!mounted) return;

    final List<ProxyElement> toDispose = [for (final g in _groups) ...g.nodes];
    setState(() {
      _isLoading = true;
      _groups.clear();
    });

    for (final proxy in toDispose) {
      proxy.dispose();
    }

    if (myGeneration != _loadingGeneration || !mounted) return;

    try {
      int retries = 4;
      List<Map<String, dynamic>> rawGroups = [];

      while (retries > 0 && rawGroups.isEmpty) {
        if (myGeneration != _loadingGeneration || !mounted) return;
        rawGroups = await widget.coreController.getProxyGroups();
        if (rawGroups.isEmpty && widget.coreController.isRunning.value) {
          await Future.delayed(const Duration(milliseconds: 400));
          retries--;
        } else {
          break;
        }
      }

      if (myGeneration != _loadingGeneration || !mounted) return;

      final List<_ProxyGroup> newGroups = [];
      for (final g in rawGroups) {
        final List<ProxyElement> nodes = [];
        for (final n in (g['nodes'] as List? ?? const [])) {
          final String name = (n['name'] ?? '').toString();
          if (name.isEmpty) continue;
          if (name.toUpperCase() == 'REJECT' ||
              name.toUpperCase() == 'REJECT-DROP') {
            continue;
          }
          nodes.add(
            ProxyElement(
              name: name,
              uuid: '',
              server: (n['server'] ?? '').toString(),
              port: n['port'] is int
                  ? n['port'] as int
                  : int.tryParse('${n['port']}') ?? 0,
            ),
          );
        }
        newGroups.add(
          _ProxyGroup(
            name: (g['name'] ?? '').toString(),
            type: (g['type'] ?? '').toString(),
            now: (g['now'] ?? '').toString(),
            icon: (g['icon'] ?? '').toString(),
            nodes: nodes,
          ),
        );
      }

      // Держим иконку обновления видимой минимальное время, чтобы вращение
      // было заметно даже при очень быстрой перезагрузке.
      final int remainingMs = 600 - loadStopwatch.elapsedMilliseconds;
      if (remainingMs > 0) {
        await Future.delayed(Duration(milliseconds: remainingMs));
      }

      if (myGeneration != _loadingGeneration || !mounted) {
        for (final g in newGroups) {
          for (final p in g.nodes) {
            p.dispose();
          }
        }
        return;
      }

      final bool isRaw = widget.coreController.activeSourceType.value == 'raw';
      setState(() {
        _groups.addAll(newGroups);
        _isLoading = false;
        // Сортировка доступна только для raw-профилей; иначе сбрасываем её,
        // чтобы скрытая сортировка от прошлого raw-профиля не переупорядочивала
        // узлы.
        if (!isRaw) {
          _currentSort = 'default';
        }
        // Clash-профили с несколькими группами по умолчанию свёрнуты (и
        // остаются свёрнутыми между перезагрузками/перезапусками), пока
        // пользователь не развернёт группу в этой сессии. У raw-профиля одна
        // группа, поэтому сворачивать её бессмысленно — шаг пропускается.
        _collapsedGroups.clear();
        if (!isRaw) {
          for (final g in newGroups) {
            if (!_userExpanded.contains(g.name)) {
              _collapsedGroups.add(g.name);
            }
          }
        }
      });
    } catch (_) {
      if (myGeneration == _loadingGeneration && mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ─── Поиск, сортировка и видимые узлы ───

  /// Сохраняет поисковый запрос (обрезанный, в нижнем регистре).
  void _onSearchInputProcessed(String value) {
    setState(() {
      _searchQuery = value.trim().toLowerCase();
    });
  }

  /// Показывает/скрывает строку поиска; при скрытии очищает запрос.
  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searchController.clear();
        _searchQuery = '';
      }
    });
  }

  /// Меняет режим сортировки видимых узлов.
  void _applySort(String sortType) {
    setState(() {
      _currentSort = sortType;
    });
  }

  /// Возвращает узлы группы с учётом поиска и выбранной сортировки.
  List<ProxyElement> _visibleNodes(_ProxyGroup g) {
    Iterable<ProxyElement> list = g.nodes;
    if (_searchQuery.isNotEmpty) {
      list = list.where((p) => p.name.toLowerCase().contains(_searchQuery));
    }
    final result = list.toList();
    if (_currentSort == 'az') {
      result.sort((a, b) => a.name.compareTo(b.name));
    } else if (_currentSort == 'za') {
      result.sort((a, b) => b.name.compareTo(a.name));
    } else if (_currentSort == 'ping') {
      result.sort(
        (a, b) => _parsePing(
          a.pingNotifier.value,
        ).compareTo(_parsePing(b.pingNotifier.value)),
      );
    }
    return result;
  }

  /// Суммарное число узлов во всех группах.
  int get _totalNodes {
    int c = 0;
    for (final g in _groups) {
      c += g.nodes.length;
    }
    return c;
  }

  /// Парсит строку пинга «N ms» в миллисекунды (999999 — значения нет).
  int _parsePing(String pingStr) {
    if (pingStr.contains('ms')) {
      return int.tryParse(pingStr.replaceAll(' ms', '').trim()) ?? 999999;
    }
    return 999999;
  }

  // ─── Тестирование задержек ───

  /// Параллельно тестирует задержку всех узлов: TCP-пинг для raw либо
  /// групповая delay-проба ядра. Сессия помечается id, чтобы новый прогон
  /// отменял предыдущий.
  void _fireParallelLatencyTest() async {
    if (_isTestingLatency) return;
    setState(() {
      _isTestingLatency = true;
    });

    final int currentSession = ++_latencyTestSessionId;

    try {
      for (final g in _groups) {
        for (final p in g.nodes) {
          p.updatePing('...');
        }
      }

      if (widget.coreController.tcpPingActive) {
        final Map<String, ProxyElement> unique = {};
        for (final g in _groups) {
          for (final p in g.nodes) {
            unique.putIfAbsent(p.name, () => p);
          }
        }
        final pingData = unique.values
            .map((e) => {'name': e.name, 'host': e.server, 'port': e.port})
            .toList();

        await widget.coreController.pingProxiesIndividually(
          pingData,
          concurrency: 16,
          onResult: (name, delay) {
            if (currentSession != _latencyTestSessionId || !mounted) return;
            for (final g in _groups) {
              for (final p in g.nodes) {
                if (p.name == name) p.updatePing(delay);
              }
            }
          },
          isCancelled: () =>
              currentSession != _latencyTestSessionId || !mounted,
        );
      } else {
        final List<_ProxyGroup> groups = List.of(_groups);
        int next = 0;
        Future<void> worker() async {
          while (next < groups.length) {
            if (currentSession != _latencyTestSessionId || !mounted) return;
            final g = groups[next++];
            final Map<String, String> delays =
                await widget.coreController.getGroupDelays(g.name);
            if (currentSession != _latencyTestSessionId || !mounted) return;
            for (final p in g.nodes) {
              p.updatePing(delays[p.name] ?? 'timeout');
            }
          }
        }

        final int conc = groups.length < 4 ? groups.length : 4;
        await Future.wait(List.generate(conc, (_) => worker()));
      }
    } finally {
      // Всегда снимаем флаг тестирования, даже если групповой/поузловой тест
      // перебил id этой сессии посреди прогона; иначе кнопка осталась бы
      // заблокированной до следующей перезагрузки списка.
      if (mounted) {
        setState(() {
          _isTestingLatency = false;
        });
      }
    }
  }

  /// Тестирует задержку узлов одной группы (TCP-пинг для raw либо delay-проба).
  Future<void> _testGroupLatency(_ProxyGroup g) async {
    final int currentSession = ++_latencyTestSessionId;
    for (final p in g.nodes) {
      p.updatePing('...');
    }

    if (widget.coreController.tcpPingActive) {
      final Map<String, ProxyElement> unique = {};
      for (final p in g.nodes) {
        unique.putIfAbsent(p.name, () => p);
      }
      final pingData = unique.values
          .map((e) => {'name': e.name, 'host': e.server, 'port': e.port})
          .toList();

      await widget.coreController.pingProxiesIndividually(
        pingData,
        concurrency: 16,
        onResult: (name, delay) {
          if (currentSession != _latencyTestSessionId || !mounted) return;
          for (final p in g.nodes) {
            if (p.name == name) p.updatePing(delay);
          }
        },
        isCancelled: () => currentSession != _latencyTestSessionId || !mounted,
      );
    } else {
      final Map<String, String> delays =
          await widget.coreController.getGroupDelays(g.name);
      if (currentSession != _latencyTestSessionId || !mounted) return;
      for (final p in g.nodes) {
        p.updatePing(delays[p.name] ?? 'timeout');
      }
    }
  }

  // ─── Выбор узла и построение интерфейса ───

  /// Выбирает узел внутри группы через ядро и обновляет текущий выбор.
  Future<void> _onSelectNode(_ProxyGroup g, ProxyElement proxy) async {
    final bool success = await widget.coreController.selectInGroup(
      g.name,
      proxy.name,
    );
    if (success && mounted) {
      setState(() {
        g.now = proxy.name;
      });
    }
  }

  /// Иконка группы: загружаемая по URL (через кэш) либо подобранная по имени.
  Widget _buildGroupIcon(_ProxyGroup g, Color accent) {
    final String icon = g.icon.trim();
    final bool isUrl =
        icon.startsWith('http://') || icon.startsWith('https://');
    final Widget fallback = Icon(
      _iconForProxyGroup(g.name),
      size: 18,
      color: accent,
    );
    if (isUrl) {
      return _CachedGroupIcon(url: icon, fallback: fallback);
    }
    return fallback;
  }

  /// Строит блок одной группы: заголовок, кнопки теста/сворачивания и сетку
  /// или список узлов.
  Widget _buildGroupBlock(_ProxyGroup g, bool isDark, String viewMode) {
    final nodes = _visibleNodes(g);
    if (nodes.isEmpty) return const SizedBox.shrink();
    final Color accent = Theme.of(context).colorScheme.primary;
    final bool selectable = g.type == 'Selector';
    final bool isRaw = widget.coreController.activeSourceType.value == 'raw';
    final bool collapsed = !isRaw && _collapsedGroups.contains(g.name);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF15181C) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: _buildGroupIcon(g, accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            g.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            selectable ? g.type : '${g.type} \u2022 auto',
                            style: TextStyle(
                              fontSize: 9,
                              color: accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (g.now.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (countryCodeFromName(g.now) != 'UN') ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: CountryFlag.fromCountryCode(
                                countryCodeFromName(g.now),
                                width: 18,
                                height: 12,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Tooltip(
                              message: cleanNodeName(g.now),
                              waitDuration: const Duration(milliseconds: 400),
                              child: Text(
                                cleanNodeName(g.now),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      isDark ? Colors.white54 : Colors.black54,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: Icon(Icons.bolt, size: 20, color: accent),
                tooltip: SettingsService().tr(
                  '\u041f\u0440\u043e\u0432\u0435\u0440\u0438\u0442\u044c \u0433\u0440\u0443\u043f\u043f\u0443',
                  'Test group',
                  '\u6d4b\u8bd5\u5206\u7ec4',
                ),
                onPressed: () => _testGroupLatency(g),
              ),
              if (!isRaw) ...[
                const SizedBox(width: 8),
                IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  icon: Icon(
                    collapsed ? Icons.expand_more : Icons.expand_less,
                    size: 20,
                    color: isDark ? Colors.grey : Colors.black54,
                  ),
                  tooltip: collapsed
                      ? SettingsService().tr(
                          '\u0420\u0430\u0437\u0432\u0435\u0440\u043d\u0443\u0442\u044c',
                          'Expand',
                          '\u5c55\u5f00',
                        )
                      : SettingsService().tr(
                          '\u0421\u0432\u0435\u0440\u043d\u0443\u0442\u044c',
                          'Collapse',
                          '\u6298\u53e0',
                        ),
                  onPressed: () {
                    setState(() {
                      if (collapsed) {
                        _collapsedGroups.remove(g.name);
                        _userExpanded.add(g.name);
                      } else {
                        _collapsedGroups.add(g.name);
                        _userExpanded.remove(g.name);
                      }
                    });
                  },
                ),
              ],
            ],
          ),
          if (!collapsed) const SizedBox(height: 10),
          if (!collapsed)
            IgnorePointer(
              ignoring: !selectable,
              child: Opacity(
                opacity: selectable ? 1.0 : 0.45,
                child: viewMode == 'list'
                    ? Column(
                        children: [
                          for (final p in nodes)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: SizedBox(
                                height: 68,
                                child: ProxyGridTile(
                                  proxy: p,
                                  isSelected: p.name == g.now,
                                  isDark: isDark,
                                  coreController: widget.coreController,
                                  onSelect: selectable
                                      ? () => _onSelectNode(g, p)
                                      : () {},
                                ),
                              ),
                            ),
                        ],
                      )
                    : GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          mainAxisExtent: 70,
                        ),
                        itemCount: nodes.length,
                        itemBuilder: (BuildContext context, int index) =>
                            ProxyGridTile(
                          proxy: nodes[index],
                          isSelected: nodes[index].name == g.now,
                          isDark: isDark,
                          coreController: widget.coreController,
                          onSelect: selectable
                              ? () => _onSelectNode(g, nodes[index])
                              : () {},
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final s = SettingsService();
    return AnimatedBuilder(
      animation: Listenable.merge([
        s.language,
        s.proxyViewMode,
        widget.coreController.isRunning,
        widget.coreController.activeSourceType,
      ]),
      builder: (context, child) {
        final String viewMode = s.proxyViewMode.value;
        final bool hasActiveProfile = widget.coreController.isRunning.value;
        final bool isRaw =
            widget.coreController.activeSourceType.value == 'raw';
        if (_isLoading && !_refreshSpin.isAnimating) {
          _refreshSpin.repeat();
        } else if (!_isLoading && _refreshSpin.isAnimating) {
          _refreshSpin
            ..stop()
            ..value = 0;
        }
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.tr(
                          '\u041f\u0440\u043e\u043a\u0441\u0438',
                          'Proxies',
                          '\u4ee3\u7406',
                        ),
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        s.tr(
                          '\u0412\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u0443\u0437\u0435\u043b \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u044f',
                          'Select a connection node',
                          '\u9009\u62e9\u8fde\u63a5\u8282\u70b9',
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? Colors.grey.withValues(alpha: 0.6)
                              : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                  if (hasActiveProfile)
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            _showSearch ? Icons.search_off : Icons.search,
                            size: 18,
                            color: _showSearch
                                ? Theme.of(context).colorScheme.primary
                                : (isDark ? Colors.grey : Colors.black54),
                          ),
                          onPressed: _totalNodes == 0 ? null : _toggleSearch,
                          tooltip: s.tr(
                            '\u041f\u043e\u0438\u0441\u043a',
                            'Search',
                            '\u641c\u7d22',
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: RotationTransition(
                            turns: _refreshSpin,
                            child: Icon(
                              Icons.refresh,
                              size: 18,
                              color: isDark ? Colors.grey : Colors.black54,
                            ),
                          ),
                          onPressed: _isLoading ? null : _loadGroups,
                          tooltip: s.tr(
                            '\u041e\u0431\u043d\u043e\u0432\u0438\u0442\u044c \u0441\u043f\u0438\u0441\u043e\u043a',
                            'Refresh list',
                            '\u5237\u65b0\u5217\u8868',
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Icon(
                            viewMode == 'grid'
                                ? Icons.view_list_rounded
                                : Icons.grid_view_rounded,
                            size: 18,
                            color: isDark ? Colors.grey : Colors.black54,
                          ),
                          onPressed: () => s.setProxyViewMode(
                            viewMode == 'grid' ? 'list' : 'grid',
                          ),
                          tooltip: s.tr(
                            '\u0421\u0435\u0442\u043a\u0430 / \u0441\u043f\u0438\u0441\u043e\u043a',
                            'Grid / list',
                            '\u7f51\u683c / \u5217\u8868',
                          ),
                        ),
                        if (isRaw) ...[
                          const SizedBox(width: 4),
                          PopupMenuButton<String>(
                            icon: Icon(
                              Icons.sort,
                              size: 18,
                              color: isDark ? Colors.grey : Colors.black54,
                            ),
                            tooltip: s.tr(
                              '\u0421\u043e\u0440\u0442\u0438\u0440\u043e\u0432\u043a\u0430',
                              'Sort',
                              '\u6392\u5e8f',
                            ),
                            onSelected: _applySort,
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'default',
                                child: Text(
                                  s.tr(
                                    '\u041f\u043e \u0443\u043c\u043e\u043b\u0447\u0430\u043d\u0438\u044e',
                                    'Default',
                                    '\u9ed8\u8ba4',
                                  ),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'ping',
                                child: Text(
                                  s.tr(
                                    '\u041f\u043e \u043f\u0438\u043d\u0433\u0443',
                                    'By Ping',
                                    '\u6309\u5ef6\u8fdf',
                                  ),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'az',
                                child: Text(
                                  s.tr(
                                    '\u041e\u0442 \u0410 \u0434\u043e \u042f',
                                    'A-Z',
                                    'A-Z',
                                  ),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'za',
                                child: Text(
                                  s.tr(
                                    '\u041e\u0442 \u042f \u0434\u043e \u0410',
                                    'Z-A',
                                    'Z-A',
                                  ),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(width: 4),
                        TextButton.icon(
                          onPressed: _isTestingLatency || _totalNodes == 0
                              ? null
                              : _fireParallelLatencyTest,
                          icon: Icon(
                            Icons.bolt,
                            size: 15,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          label: Text(
                            _isTestingLatency
                                ? s.tr(
                                    '\u0422\u0435\u0441\u0442\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435...',
                                    'Testing...',
                                    '\u6d4b\u8bd5\u4e2d...',
                                  )
                                : s.tr(
                                    '\u0422\u0435\u0441\u0442 \u0437\u0430\u0434\u0435\u0440\u0436\u043a\u0438',
                                    'Latency Test',
                                    '\u5ef6\u8fdf\u6d4b\u8bd5',
                                  ),
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.grey : Colors.black54,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                alignment: Alignment.topCenter,
                child: _showSearch
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 16),
                          Container(
                            decoration: BoxDecoration(
                              boxShadow: isDark
                                  ? []
                                  : [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.02,
                                        ),
                                        blurRadius: 5,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                            ),
                            child: TextField(
                              controller: _searchController,
                              onChanged: _onSearchInputProcessed,
                              enabled: _totalNodes > 0,
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                              decoration: InputDecoration(
                                hintText: _totalNodes == 0
                                    ? s.tr(
                                        '\u041f\u043e\u0438\u0441\u043a \u043d\u0435\u0434\u043e\u0441\u0442\u0443\u043f\u0435\u043d',
                                        'Search unavailable',
                                        '\u641c\u7d22\u4e0d\u53ef\u7528',
                                      )
                                    : s.tr(
                                        '\u041f\u043e\u0438\u0441\u043a \u043f\u0440\u043e\u043a\u0441\u0438 \u043f\u043e \u0442\u0435\u0433\u0443 \u0438\u043b\u0438 \u0441\u0442\u0440\u0430\u043d\u0435',
                                        'Search proxy by tag or country',
                                        '\u6309\u6807\u7b7e\u6216\u56fd\u5bb6/\u5730\u533a\u641c\u7d22\u4ee3\u7406',
                                      ),
                                hintStyle: TextStyle(
                                  color:
                                      isDark ? Colors.white38 : Colors.black38,
                                ),
                                isDense: true,
                                fillColor: isDark
                                    ? const Color(0xFF111315)
                                    : Colors.white,
                                filled: true,
                                prefixIcon: Icon(
                                  Icons.search,
                                  size: 16,
                                  color:
                                      isDark ? Colors.white24 : Colors.black38,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: isDark
                                      ? BorderSide.none
                                      : BorderSide(
                                          color: Colors.black.withValues(
                                            alpha: 0.05,
                                          ),
                                        ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: isDark
                                      ? BorderSide.none
                                      : BorderSide(
                                          color: Colors.black.withValues(
                                            alpha: 0.05,
                                          ),
                                        ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _isLoading
                    ? Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: isDark ? Colors.white24 : Colors.black26,
                          ),
                        ),
                      )
                    : _groups.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.network_ping,
                                  size: 40,
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.15)
                                      : Colors.black12,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  s.tr(
                                    '\u041d\u0435\u0442 \u0430\u043a\u0442\u0438\u0432\u043d\u044b\u0445 \u043f\u0440\u043e\u043a\u0441\u0438',
                                    'No active proxies',
                                    '\u6ca1\u6709\u53ef\u7528\u4ee3\u7406',
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
                                    '\u0421\u043d\u0430\u0447\u0430\u043b\u0430 \u0434\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0438 \u0432\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u043f\u0440\u043e\u0444\u0438\u043b\u044c \u0432\u043e \u0432\u043a\u043b\u0430\u0434\u043a\u0435 "\u041f\u0440\u043e\u0444\u0438\u043b\u0438"',
                                    'First, add and select a profile in the "Profiles" tab',
                                    '\u8bf7\u5148\u5728"\u914d\u7f6e"\u6807\u7b7e\u9875\u4e2d\u6dfb\u52a0\u5e76\u9009\u62e9\u4e00\u4e2a\u914d\u7f6e',
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
                        : ScrollConfiguration(
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(scrollbars: false),
                            child: ListView.builder(
                              physics: const BouncingScrollPhysics(),
                              itemCount: _groups.length,
                              itemBuilder: (BuildContext context, int index) =>
                                  _buildGroupBlock(
                                _groups[index],
                                isDark,
                                viewMode,
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
}

/// Группа прокси: имя, тип, текущий выбранный узел, иконка и список узлов.
class _ProxyGroup {
  final String name;
  final String type;
  String now;
  final String icon;
  final List<ProxyElement> nodes;
  _ProxyGroup({
    required this.name,
    required this.type,
    required this.now,
    this.icon = '',
    required this.nodes,
  });
}

// ─── Вспомогательные функции: иконки, страны, имена ───

/// Подбирает иконку для группы по ключевым словам в её имени.
IconData _iconForProxyGroup(String name) {
  final n = name.toLowerCase();
  if (n.contains('discord')) return Icons.forum_rounded;
  if (n.contains('telegram') ||
      n.contains('\u0442\u0435\u043b\u0435\u0433\u0440\u0430\u043c')) {
    return Icons.send_rounded;
  }
  if (n.contains('youtube') || n.contains('\u044e\u0442\u0443\u0431')) {
    return Icons.ondemand_video_rounded;
  }
  if (n.contains('chatgpt') ||
      n.contains('openai') ||
      n.contains('gpt') ||
      n.contains('\u043d\u0435\u0439\u0440\u043e\u0441\u0435\u0442')) {
    return Icons.auto_awesome_rounded;
  }
  if (n.contains('\u0442\u043e\u0440\u0440\u0435\u043d\u0442') ||
      n.contains('torrent')) {
    return Icons.download_rounded;
  }
  if (n.contains('\u0438\u0433\u0440') || n.contains('game')) {
    return Icons.sports_esports_rounded;
  }
  if (n.contains('\u0440\u043e\u0441\u0441\u0438\u0439\u0441\u043a') ||
      n.contains('\u0440\u043e\u0441\u0441\u0438\u044f') ||
      n.contains('russia')) {
    return Icons.flag_rounded;
  }
  if (n.contains('\u0437\u0430\u0440\u0443\u0431\u0435\u0436') ||
      n.contains('foreign') ||
      n.contains('global') ||
      n.contains('\u0433\u043b\u043e\u0431\u0430\u043b')) {
    return Icons.public_rounded;
  }
  if (n.contains('fast') || n.contains('\u0431\u044b\u0441\u0442\u0440')) {
    return Icons.bolt_rounded;
  }
  if (n.contains('direct') || n.contains('\u043f\u0440\u044f\u043c')) {
    return Icons.arrow_outward_rounded;
  }
  return Icons.dns_rounded;
}

// Коды стран ISO-3166-1 alpha-2. Используются для проверки ведущего
// двухбуквенного токена в имени узла, чтобы флаг рисовался только для реального
// кода страны, а не для негеографического префикса вроде «FAST», «VIP» или «PRO».
const Set<String> _isoAlpha2Codes = {
  'AD',
  'AE',
  'AF',
  'AG',
  'AI',
  'AL',
  'AM',
  'AO',
  'AQ',
  'AR',
  'AS',
  'AT',
  'AU',
  'AW',
  'AX',
  'AZ',
  'BA',
  'BB',
  'BD',
  'BE',
  'BF',
  'BG',
  'BH',
  'BI',
  'BJ',
  'BL',
  'BM',
  'BN',
  'BO',
  'BQ',
  'BR',
  'BS',
  'BT',
  'BV',
  'BW',
  'BY',
  'BZ',
  'CA',
  'CC',
  'CD',
  'CF',
  'CG',
  'CH',
  'CI',
  'CK',
  'CL',
  'CM',
  'CN',
  'CO',
  'CR',
  'CU',
  'CV',
  'CW',
  'CX',
  'CY',
  'CZ',
  'DE',
  'DJ',
  'DK',
  'DM',
  'DO',
  'DZ',
  'EC',
  'EE',
  'EG',
  'EH',
  'ER',
  'ES',
  'ET',
  'FI',
  'FJ',
  'FK',
  'FM',
  'FO',
  'FR',
  'GA',
  'GB',
  'GD',
  'GE',
  'GF',
  'GG',
  'GH',
  'GI',
  'GL',
  'GM',
  'GN',
  'GP',
  'GQ',
  'GR',
  'GS',
  'GT',
  'GU',
  'GW',
  'GY',
  'HK',
  'HM',
  'HN',
  'HR',
  'HT',
  'HU',
  'ID',
  'IE',
  'IL',
  'IM',
  'IN',
  'IO',
  'IQ',
  'IR',
  'IS',
  'IT',
  'JE',
  'JM',
  'JO',
  'JP',
  'KE',
  'KG',
  'KH',
  'KI',
  'KM',
  'KN',
  'KP',
  'KR',
  'KW',
  'KY',
  'KZ',
  'LA',
  'LB',
  'LC',
  'LI',
  'LK',
  'LR',
  'LS',
  'LT',
  'LU',
  'LV',
  'LY',
  'MA',
  'MC',
  'MD',
  'ME',
  'MF',
  'MG',
  'MH',
  'MK',
  'ML',
  'MM',
  'MN',
  'MO',
  'MP',
  'MQ',
  'MR',
  'MS',
  'MT',
  'MU',
  'MV',
  'MW',
  'MX',
  'MY',
  'MZ',
  'NA',
  'NC',
  'NE',
  'NF',
  'NG',
  'NI',
  'NL',
  'NO',
  'NP',
  'NR',
  'NU',
  'NZ',
  'OM',
  'PA',
  'PE',
  'PF',
  'PG',
  'PH',
  'PK',
  'PL',
  'PM',
  'PN',
  'PR',
  'PS',
  'PT',
  'PW',
  'PY',
  'QA',
  'RE',
  'RO',
  'RS',
  'RU',
  'RW',
  'SA',
  'SB',
  'SC',
  'SD',
  'SE',
  'SG',
  'SH',
  'SI',
  'SJ',
  'SK',
  'SL',
  'SM',
  'SN',
  'SO',
  'SR',
  'SS',
  'ST',
  'SV',
  'SX',
  'SY',
  'SZ',
  'TC',
  'TD',
  'TF',
  'TG',
  'TH',
  'TJ',
  'TK',
  'TL',
  'TM',
  'TN',
  'TO',
  'TR',
  'TT',
  'TV',
  'TW',
  'TZ',
  'UA',
  'UG',
  'UM',
  'US',
  'UY',
  'UZ',
  'VA',
  'VC',
  'VE',
  'VG',
  'VI',
  'VN',
  'VU',
  'WF',
  'WS',
  'YE',
  'YT',
  'ZA',
  'ZM',
  'ZW',
};

/// Определяет код страны по имени узла: сначала по эмодзи-флагу, затем по
/// ключевым словам и кодам, иначе по ведущему ISO-токену. «UN» — не найдено.
String countryCodeFromName(String name) {
  String code = 'UN';

  final flagRegExp = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);
  final flagMatch = flagRegExp.firstMatch(name);
  if (flagMatch != null) {
    final runes = flagMatch.group(0)!.runes.toList();
    if (runes.length == 2) {
      code = String.fromCharCode(runes[0] - 0x1F1E6 + 65) +
          String.fromCharCode(runes[1] - 0x1F1E6 + 65);
    }
  }

  final clean = name.trim().toUpperCase();

  if (code == 'UN') {
    if (clean.contains('\u0413\u0415\u0420\u041c\u0410\u041d\u0418\u042f') ||
        clean.contains('GERMANY') ||
        RegExp(r'\bDE\b').hasMatch(clean)) {
      code = 'DE';
    } else if (clean.contains('\u0420\u041e\u0421\u0421\u0418\u042f') ||
        clean.contains('RUSSIA') ||
        RegExp(r'\bRU\b').hasMatch(clean)) {
      code = 'RU';
    } else if (clean.contains(
          '\u041d\u0418\u0414\u0415\u0420\u041b\u0410\u041d\u0414\u042b',
        ) ||
        clean.contains('NETHERLANDS') ||
        RegExp(r'\bNL\b').hasMatch(clean)) {
      code = 'NL';
    } else if (clean.contains('\u0428\u0412\u0415\u0426\u0418\u042f') ||
        clean.contains('SWEDEN') ||
        RegExp(r'\bSE\b').hasMatch(clean)) {
      code = 'SE';
    } else if (clean.contains('\u041f\u041e\u041b\u042c\u0428\u0410') ||
        clean.contains('POLAND') ||
        RegExp(r'\bPL\b').hasMatch(clean)) {
      code = 'PL';
    } else if (clean.contains(
          '\u0424\u0418\u041d\u041b\u042f\u041d\u0414\u0418\u042f',
        ) ||
        clean.contains('FINLAND') ||
        RegExp(r'\bFI\b').hasMatch(clean)) {
      code = 'FI';
    } else if (clean.contains('\u0424\u0420\u0410\u041d\u0426\u0418\u042f') ||
        clean.contains('FRANCE') ||
        RegExp(r'\bFR\b').hasMatch(clean)) {
      code = 'FR';
    } else if (clean.contains('\u0421\u0428\u0410') ||
        clean.contains('USA') ||
        clean.contains('UNITED STATES') ||
        RegExp(r'\bUS\b').hasMatch(clean)) {
      code = 'US';
    } else if (clean.contains(
          '\u0412\u0415\u041b\u0418\u041a\u041e\u0411\u0420\u0418\u0422\u0410\u041d\u0418\u042f',
        ) ||
        RegExp(r'\bUK\b').hasMatch(clean) ||
        clean.contains('LONDON') ||
        RegExp(r'\bGB\b').hasMatch(clean)) {
      code = 'GB';
    } else if (clean.contains('\u042f\u041f\u041e\u041d\u0418\u042f') ||
        clean.contains('JAPAN') ||
        RegExp(r'\bJP\b').hasMatch(clean)) {
      code = 'JP';
    } else if (clean.contains(
          '\u0421\u0418\u041d\u0413\u0410\u041f\u0423\u0420',
        ) ||
        clean.contains('SINGAPORE') ||
        RegExp(r'\bSG\b').hasMatch(clean)) {
      code = 'SG';
    } else if (clean.contains('\u0413\u041e\u041d\u041a\u041e\u041d\u0413') ||
        clean.contains('HONG KONG') ||
        RegExp(r'\bHK\b').hasMatch(clean)) {
      code = 'HK';
    } else if (clean.contains('\u0422\u0423\u0420\u0426\u0418\u042f') ||
        clean.contains('TURKEY') ||
        RegExp(r'\bTR\b').hasMatch(clean)) {
      code = 'TR';
    } else if (clean.contains(
          '\u041a\u0410\u0417\u0410\u0425\u0421\u0422\u0410\u041d',
        ) ||
        clean.contains('KAZAKHSTAN') ||
        RegExp(r'\bKZ\b').hasMatch(clean)) {
      code = 'KZ';
    } else if (clean.contains('\u0423\u041a\u0420\u0410\u0418\u041d\u0410') ||
        clean.contains('UKRAINE') ||
        RegExp(r'\bUA\b').hasMatch(clean)) {
      code = 'UA';
    } else {
      // Принимаем ведущий двухбуквенный токен только если это реальный код
      // ISO-3166. Прошлая версия принимала ЛЮБОЙ префикс из 2–3 букв, поэтому
      // имена вроде «FAST ...» или «VIP ...» давали ложные/пустые флаги.
      final match = RegExp(r'^([A-Z]{2})\b').firstMatch(clean);
      if (match != null && _isoAlpha2Codes.contains(match.group(1))) {
        code = match.group(1)!;
      }
    }
  }

  if (code.length > 2) code = code.substring(0, 2);
  return code;
}

/// Очищает имя узла от эмодзи-флагов и ведущего кода страны для отображения.
String cleanNodeName(String rawName) {
  String name = rawName;
  name = name
      .replaceAll(RegExp(r'[\u{1F1E6}-\u{1F1FF}|]', unicode: true), '')
      .trim();
  final List<String> codes = [
    'DE',
    'RU',
    'NL',
    'SE',
    'PL',
    'FI',
    'FR',
    'US',
    'GB',
    'JP',
    'SG',
    'HK',
    'TR',
    'KZ',
    'UA',
  ];
  for (final c in codes) {
    if (name.toUpperCase().startsWith('$c ') ||
        name.toUpperCase().startsWith('$c-')) {
      name = name.substring(c.length + 1).trim();
    }
  }
  return name.isEmpty ? rawName : name;
}

// Иконка группы, которая один раз скачивается и кэшируется на диске (имя файла —
// хэш URL иконки), чтобы не запрашивать её из сети при каждом перезапуске.
class _CachedGroupIcon extends StatefulWidget {
  final String url;
  final Widget fallback;
  const _CachedGroupIcon({required this.url, required this.fallback});

  @override
  State<_CachedGroupIcon> createState() => _CachedGroupIconState();
}

class _CachedGroupIconState extends State<_CachedGroupIcon> {
  static Directory? _cacheDir;
  Uint8List? _bytes;
  bool _failed = false;

  bool get _isSvg => widget.url.toLowerCase().split('?').first.endsWith('.svg');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CachedGroupIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  // Детерминированный 32-битный хэш FNV-1a для стабильных имён файлов кэша.
  static String _hash(String input) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  Future<File> _fileFor(String url) async {
    final Directory dir = _cacheDir ??= Directory(
      path.join((await getApplicationSupportDirectory()).path, 'icon_cache'),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final String ext = _isSvg ? 'svg' : 'img';
    return File(path.join(dir.path, '${_hash(url)}.$ext'));
  }

  Future<void> _load() async {
    final String url = widget.url;
    try {
      final File file = await _fileFor(url);
      if (await file.exists() && await file.length() > 0) {
        final bytes = await file.readAsBytes();
        if (!mounted || widget.url != url) return;
        setState(() => _bytes = bytes);
        return;
      }

      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close().timeout(
              const Duration(seconds: 10),
            );
        if (response.statusCode != 200) {
          if (mounted && widget.url == url) setState(() => _failed = true);
          return;
        }
        // Читаем поток ответа вручную с ограничением в 1 МБ (иконки маленькие),
        // чтобы не зависеть от consolidateHttpClientResponseBytes из foundation.
        final List<int> buffer = <int>[];
        bool tooLarge = false;
        await for (final List<int> chunk in response) {
          buffer.addAll(chunk);
          if (buffer.length > 1024 * 1024) {
            tooLarge = true;
            break;
          }
        }
        if (tooLarge || buffer.isEmpty) {
          if (mounted && widget.url == url) setState(() => _failed = true);
          return;
        }
        final Uint8List data = Uint8List.fromList(buffer);
        try {
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsBytes(data, flush: true);
          if (await file.exists()) await file.delete();
          await tmp.rename(file.path);
        } catch (_) {}
        if (!mounted || widget.url != url) return;
        setState(() => _bytes = data);
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      if (mounted && widget.url == url) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (_failed || bytes == null) return widget.fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: _isSvg
          ? SvgPicture.memory(
              bytes,
              width: 20,
              height: 20,
              fit: BoxFit.contain,
              placeholderBuilder: (context) => widget.fallback,
            )
          : Image.memory(
              bytes,
              width: 20,
              height: 20,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => widget.fallback,
            ),
    );
  }
}

/// Плитка одного узла: страна/флаг, имя, кнопка теста и значение пинга
/// (зелёный <150 мс, оранжевый <300 мс, иначе красный).
class ProxyGridTile extends StatelessWidget {
  final ProxyElement proxy;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onSelect;
  final CoreController coreController;

  const ProxyGridTile({
    super.key,
    required this.proxy,
    required this.isSelected,
    required this.isDark,
    required this.onSelect,
    required this.coreController,
  });

  Widget _buildCountryCapsule(String name, Color accent) {
    final String code = countryCodeFromName(name);
    final bool hasCountry = code != 'UN';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withValues(alpha: 0.3), width: 1),
      ),
      child: hasCountry
          ? ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: CountryFlag.fromCountryCode(code, width: 18, height: 12),
            )
          : Text(
              _nonCountryLabel(name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: accent,
                letterSpacing: 0.5,
              ),
            ),
    );
  }

  String _nonCountryLabel(String name) {
    final String upper = name.trim().toUpperCase();
    if (upper.contains('DIRECT')) return 'DIRECT';
    if (upper.startsWith('REJECT')) return 'REJECT';
    return name.trim();
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark
                  ? const Color(0xFF1D2126)
                  : accent.withValues(alpha: 0.08))
              : (isDark ? const Color(0xFF1E2227) : Colors.white),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? accent
                : (isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.05)),
            width: isSelected ? 1.5 : 1.0,
          ),
          boxShadow: isDark
              ? []
              : [
                  BoxShadow(
                    color: isSelected
                        ? accent.withValues(alpha: 0.15)
                        : Colors.black.withValues(alpha: 0.03),
                    blurRadius: isSelected ? 8 : 5,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(child: _buildCountryCapsule(proxy.name, accent)),
                const SizedBox(width: 6),
                Row(
                  children: [
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        Icons.bolt,
                        size: 16,
                        color: isDark ? Colors.white54 : Colors.black38,
                      ),
                      tooltip: SettingsService().tr(
                        '\u041f\u0440\u043e\u0432\u0435\u0440\u0438\u0442\u044c \u0443\u0437\u0435\u043b',
                        'Test node',
                        '\u6d4b\u8bd5\u8282\u70b9',
                      ),
                      onPressed: () async {
                        if (proxy.pingNotifier.value == '...') return;
                        proxy.updatePing('...');
                        final delay = await coreController.getProxyDelay(
                          proxy.name,
                          host: proxy.server,
                          port: proxy.port,
                        );
                        proxy.updatePing(delay);
                      },
                    ),
                    const SizedBox(width: 4),
                    ValueListenableBuilder<String>(
                      valueListenable: proxy.pingNotifier,
                      builder: (context, pingValue, child) {
                        Color pingColor =
                            isDark ? Colors.white38 : Colors.black38;
                        if (pingValue.contains('ms')) {
                          final int? ms = int.tryParse(
                            pingValue.replaceAll(' ms', ''),
                          );
                          if (ms != null) {
                            pingColor = ms < 150
                                ? const Color(0xFF2ECC71)
                                : (ms < 300
                                    ? Colors.orangeAccent
                                    : Colors.redAccent);
                          }
                        } else if (pingValue == '...') {
                          pingColor = Colors.amber;
                        }
                        return Text(
                          pingValue,
                          style: TextStyle(
                            fontSize: 11,
                            color: pingColor,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w500,
                            fontFamily: 'monospace',
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Tooltip(
              message: cleanNodeName(proxy.name),
              waitDuration: const Duration(milliseconds: 400),
              child: Text(
                cleanNodeName(proxy.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? (isDark ? Colors.white : Colors.black87)
                      : (isDark ? Colors.white70 : Colors.black87),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
