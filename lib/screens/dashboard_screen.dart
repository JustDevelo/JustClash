// ═══════════════════════════════════════════════════════════════════════════
// DashboardScreen — главный экран: кнопка подключения, таймер, IP и скорость.
//
// Назначение файла:
//   • Большая круглая кнопка подключения/отключения VPN с анимациями состояний.
//   • Таймер длительности соединения (чч:мм:сс).
//   • «Пилюля» с внешним IP (только для raw-профилей) и карточка скоростей.
// Экран реактивный: подписан на ValueNotifier из CoreController и SettingsService.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/core_controller.dart';
import '../services/settings_service.dart';
import '../widgets/animated_ellipsis_text.dart';

/// Главный экран приложения (вкладка «Главная»).
class DashboardScreen extends StatelessWidget {
  final CoreController coreController;
  final VoidCallback onToggleConnect;

  const DashboardScreen({
    super.key,
    required this.coreController,
    required this.onToggleConnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final Color accent = theme.colorScheme.primary;

    return ValueListenableBuilder<String>(
      valueListenable: SettingsService().language,
      builder: (context, lang, child) {
        final s = SettingsService();
        return SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.tr('Главная', 'Dashboard', '主页'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w300,
                  letterSpacing: 0.5,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.9)
                      : Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.tr(
                  'Управление подключением',
                  'Connection Management',
                  '连接管理',
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.3)
                      : Colors.black54,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: ValueListenableBuilder<bool>(
                  valueListenable: coreController.isRunning,
                  builder: (context, isRunning, _) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: coreController.isVpnConnected,
                      builder: (context, isConnected, child) {
                        return ValueListenableBuilder<bool>(
                          valueListenable: coreController.isToggling,
                          builder: (context, isToggling, _) {
                            final bool canConnect = isRunning;
                            return Column(
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (isToggling) return;
                                    if (canConnect) {
                                      onToggleConnect();
                                    } else {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            s.tr(
                                              'Для подключения необходимо сначала активировать профиль во вкладке "Профили"',
                                              'Please activate a profile in the "Profiles" tab first',
                                              '请先在"配置"标签页中激活一个配置',
                                            ),
                                          ),
                                          backgroundColor: Colors.orangeAccent,
                                        ),
                                      );
                                    }
                                  },
                                  child: AnimatedScale(
                                    scale: isConnected ? 1.05 : 1.0,
                                    duration: const Duration(milliseconds: 800),
                                    curve: Curves.easeInOutSine,
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      curve: Curves.easeInOut,
                                      width: 160,
                                      height: 160,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        // Заливку всегда задаём градиентом и никогда
                                        // не переключаемся между `color` и `gradient`:
                                        // BoxDecoration.lerp в середине анимации кратко
                                        // гасит ОБА до прозрачного при переходе от
                                        // сплошного цвета к градиенту — из-за этого кнопка
                                        // на кадр теряла заливку при подключении.
                                        // Кодируя покой/неактивность как однородные
                                        // градиенты, мы держим переход градиент->
                                        // градиент идеально стабильным.
                                        gradient: (isConnected && canConnect)
                                            ? RadialGradient(
                                                radius: 0.95,
                                                colors: [
                                                  accent.withValues(
                                                    alpha: isDark ? 0.26 : 0.18,
                                                  ),
                                                  accent.withValues(
                                                    alpha: isDark ? 0.05 : 0.03,
                                                  ),
                                                ],
                                              )
                                            : RadialGradient(
                                                radius: 0.95,
                                                colors: !canConnect
                                                    ? [
                                                        isDark
                                                            ? Colors.white
                                                                .withValues(
                                                                alpha: 0.02,
                                                              )
                                                            : Colors.black
                                                                .withValues(
                                                                alpha: 0.02,
                                                              ),
                                                        isDark
                                                            ? Colors.white
                                                                .withValues(
                                                                alpha: 0.02,
                                                              )
                                                            : Colors.black
                                                                .withValues(
                                                                alpha: 0.02,
                                                              ),
                                                      ]
                                                    : [
                                                        isDark
                                                            ? const Color(
                                                                0xFF14171A,
                                                              )
                                                            : Colors.white,
                                                        isDark
                                                            ? const Color(
                                                                0xFF14171A,
                                                              )
                                                            : Colors.white,
                                                      ],
                                              ),
                                        border: Border.all(
                                          color: !canConnect
                                              ? (isDark
                                                  ? Colors.white12
                                                  : Colors.black12)
                                              : isConnected
                                                  ? accent.withValues(
                                                      alpha: 0.55)
                                                  : (isDark
                                                      ? Colors.white.withValues(
                                                          alpha: 0.14,
                                                        )
                                                      : Colors.black.withValues(
                                                          alpha: 0.12,
                                                        )),
                                          width: isConnected && canConnect
                                              ? 2
                                              : 1.5,
                                        ),
                                        boxShadow: isConnected && canConnect
                                            ? [
                                                BoxShadow(
                                                  color: accent.withValues(
                                                    alpha: isDark ? 0.22 : 0.18,
                                                  ),
                                                  blurRadius: 18,
                                                  spreadRadius: 0,
                                                ),
                                                BoxShadow(
                                                  color: accent.withValues(
                                                    alpha: isDark ? 0.10 : 0.08,
                                                  ),
                                                  blurRadius: 44,
                                                  spreadRadius: 6,
                                                ),
                                              ]
                                            : (!isDark &&
                                                    canConnect &&
                                                    !isConnected)
                                                ? [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withValues(
                                                              alpha: 0.05),
                                                      blurRadius: 15,
                                                      spreadRadius: 1,
                                                    ),
                                                  ]
                                                : [],
                                      ),
                                      child: Center(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            isToggling
                                                ? SizedBox(
                                                    width: 38,
                                                    height: 38,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2.5,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                              Color>(accent),
                                                    ),
                                                  )
                                                : Icon(
                                                    Icons.power_settings_new,
                                                    color: !canConnect
                                                        ? (isDark
                                                            ? Colors.white12
                                                            : Colors.black26)
                                                        : isConnected
                                                            ? accent
                                                            : Colors.grey,
                                                    size: 38,
                                                  ),
                                            const SizedBox(height: 10),
                                            AnimatedEllipsisText(
                                              text: isToggling
                                                  ? (isConnected
                                                      ? s.tr(
                                                          'ОТКЛЮЧЕНИЕ…',
                                                          'DISCONNECTING…',
                                                          '断开中…',
                                                        )
                                                      : s.tr(
                                                          'ПОДКЛЮЧЕНИЕ…',
                                                          'CONNECTING…',
                                                          '连接中…',
                                                        ))
                                                  : !canConnect
                                                      ? s.tr(
                                                          'НЕТ ПРОФИЛЯ',
                                                          'NO PROFILE',
                                                          '无配置',
                                                        )
                                                      : isConnected
                                                          ? s.tr(
                                                              'ПОДКЛЮЧЕНО',
                                                              'CONNECTED',
                                                              '已连接',
                                                            )
                                                          : s.tr(
                                                              'ПОДКЛЮЧИТЬСЯ',
                                                              'CONNECT',
                                                              '连接',
                                                            ),
                                              style: TextStyle(
                                                color: !canConnect
                                                    ? (isDark
                                                        ? Colors.white24
                                                        : Colors.black26)
                                                    : isConnected
                                                        ? accent
                                                        : Colors.grey,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 10,
                                                letterSpacing: 1.8,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                AnimatedSize(
                                  duration: const Duration(milliseconds: 400),
                                  curve: Curves.easeInOutBack,
                                  child: Column(
                                    children: [
                                      if (isConnected) ...[
                                        const SizedBox(height: 20),
                                        ValueListenableBuilder<int>(
                                          valueListenable:
                                              coreController.connectedSeconds,
                                          builder: (context, seconds, child) {
                                            final duration = Duration(
                                              seconds: seconds,
                                            );
                                            final String formattedTime =
                                                '${duration.inHours.toString().padLeft(2, '0')}:${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
                                            return Text(
                                              formattedTime,
                                              style: TextStyle(
                                                fontSize: 32,
                                                fontWeight: FontWeight.bold,
                                                color: accent,
                                                fontFamily: 'monospace',
                                                letterSpacing: 2.0,
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                      ValueListenableBuilder<String>(
                                        valueListenable:
                                            coreController.activeSourceType,
                                        builder: (context, sourceType, _) {
                                          if (sourceType != 'raw') {
                                            return const SizedBox.shrink();
                                          }
                                          return Column(
                                            children: [
                                              const SizedBox(height: 16),
                                              _buildIpPill(context, isDark),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 32),
              _buildSpeedCard(context, isDark),
            ],
          ),
        );
      },
    );
  }

  // ─── Виджеты-компоненты экрана ───

  /// «Пилюля» с текущим внешним IP (только для raw-профилей). Одиночный
  /// тап обновляет IP, двойной тап включает/выключает размытие IP.
  Widget _buildIpPill(BuildContext context, bool isDark) {
    return ValueListenableBuilder<String>(
      valueListenable: coreController.currentIp,
      builder: (context, ip, _) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              coreController.currentIp.value = SettingsService().tr(
                'Получение IP...',
                'Fetching IP...',
                '正在获取 IP...',
              );
              coreController.fetchCurrentIp();
            },
            onDoubleTap: () {
              SettingsService().blurIp.value = !SettingsService().blurIp.value;
              SettingsService().saveSettings();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDark ? Colors.white10 : Colors.black12,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: SettingsService().blurIp,
                    builder: (context, isBlurred, _) {
                      return ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: isBlurred ? 6.0 : 0.0,
                          sigmaY: isBlurred ? 6.0 : 0.0,
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.2),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          ),
                          child: Text(
                            ip,
                            key: ValueKey(ip),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white70 : Colors.black87,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Карточка скорости с колонками «Загрузка» и «Отдача».
  Widget _buildSpeedCard(BuildContext context, bool isDark) {
    final s = SettingsService();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF111315) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.03)
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _speedColumn(
            isDark: isDark,
            label: s.tr('Загрузка', 'Download', '下载'),
            icon: Icons.arrow_downward,
            color: Theme.of(context).colorScheme.primary,
            bytesListenable: coreController.downloadSpeedBytes,
            textListenable: coreController.downloadSpeed,
          ),
          Container(
            width: 1,
            height: 40,
            color: isDark ? Colors.white10 : Colors.black12,
          ),
          _speedColumn(
            isDark: isDark,
            label: s.tr('Отдача', 'Upload', '上传'),
            icon: Icons.arrow_upward,
            color: Theme.of(context).colorScheme.primary,
            bytesListenable: coreController.uploadSpeedBytes,
            textListenable: coreController.uploadSpeed,
          ),
        ],
      ),
    );
  }

  /// Одна колонка скорости: иконка, числовое значение и подпись. Серый
  /// цвет при нулевой скорости.
  Widget _speedColumn({
    required bool isDark,
    required String label,
    required IconData icon,
    required Color color,
    required ValueListenable<int> bytesListenable,
    required ValueListenable<String> textListenable,
  }) {
    return ValueListenableBuilder<int>(
      valueListenable: bytesListenable,
      builder: (context, rawSpeed, child) {
        final bool isZero = rawSpeed == 0;
        return Column(
          children: [
            Icon(icon, color: isZero ? Colors.grey : color, size: 20),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: textListenable,
              builder: (context, textSpeed, _) {
                return Text(
                  textSpeed,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 16,
                    color: isZero
                        ? (isDark ? Colors.white70 : Colors.black54)
                        : color,
                    fontFamily: 'monospace',
                  ),
                );
              },
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: isDark ? Colors.grey : Colors.black54,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        );
      },
    );
  }
}
