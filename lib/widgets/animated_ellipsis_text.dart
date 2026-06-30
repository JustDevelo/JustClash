import 'dart:async';
import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  AnimatedEllipsisText
//  Текстовый виджет с «бегущим» многоточием в конце строки.
//
//  Зачем нужен: для статусов вида «Подключение…», «Тестирование…», где точки
//  должны циклично меняться (. → .. → ...), не сдвигая соседние элементы.
//
//  Логика:
//   • Если [text] оканчивается точками (`.`) или символом многоточия (\u2026),
//     эти хвостовые точки убираются, а вместо них рисуется анимированная серия.
//   • Недостающие позиции добиваются пробелами — ширина строки постоянна,
//     поэтому layout не «дёргается» при смене числа точек.
//   • Если хвостовых точек нет — ведёт себя как обычный [Text].
// ═══════════════════════════════════════════════════════════════════════════

/// Замена [Text], анимирующая хвостовое многоточие (подробности — в шапке файла).
class AnimatedEllipsisText extends StatefulWidget {
  // ─────────────────────────────── Параметры ───────────────────────────────

  /// Исходный текст. Хвостовые точки/многоточие будут анимированы.
  final String text;

  /// Стиль текста (как у обычного [Text]).
  final TextStyle? style;

  /// Горизонтальное выравнивание текста.
  final TextAlign? textAlign;

  /// Максимальное число строк.
  final int? maxLines;

  /// Поведение при переполнении текста.
  final TextOverflow? overflow;

  /// Сколько точек максимум показывать в анимации (по умолчанию 3).
  final int maxDots;

  /// Интервал смены количества точек (скорость анимации).
  final Duration interval;

  const AnimatedEllipsisText({
    super.key,
    required this.text,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.maxDots = 3,
    this.interval = const Duration(milliseconds: 400),
  });

  @override
  State<AnimatedEllipsisText> createState() => _AnimatedEllipsisTextState();
}

class _AnimatedEllipsisTextState extends State<AnimatedEllipsisText> {
  // ───────────────────────── Внутреннее состояние ──────────────────────────

  /// Регулярное выражение: одна+ хвостовая точка/многоточие и пробелы до конца.
  static final RegExp _trailingDots = RegExp(r'[.\u2026]+\s*$');

  /// Таймер цикличной анимации (null, когда анимация не запущена).
  Timer? _timer;

  /// Текущее количество отображаемых точек (от 1 до [maxDots]).
  int _count = 1;

  /// Нужна ли анимация: только если текст оканчивается точками/многоточием.
  bool get _animated => _trailingDots.hasMatch(widget.text);

  /// Базовая часть текста без хвостовых точек.
  String get _base => widget.text.replaceAll(_trailingDots, '');

  // ────────────────────────────── Жизненный цикл ───────────────────────────

  @override
  void initState() {
    super.initState();
    // Запускаем анимацию сразу, если текст её предполагает.
    if (_animated) _start();
  }

  /// (Пере)запуск периодического таймера: сбрасывает счётчик и крутит точки.
  void _start() {
    _timer?.cancel();
    _count = 1;
    _timer = Timer.periodic(widget.interval, (_) {
      // Защита от обновления после удаления виджета из дерева.
      if (!mounted) return;
      setState(() {
        // По кругу: дойдя до максимума, возвращаемся к одной точке.
        _count = _count >= widget.maxDots ? 1 : _count + 1;
      });
    });
  }

  @override
  void didUpdateWidget(AnimatedEllipsisText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Реагируем только на смену текста или интервала анимации.
    if (oldWidget.text != widget.text ||
        oldWidget.interval != widget.interval) {
      if (_animated) {
        _start();
      } else {
        // Текст перестал требовать анимации — гасим таймер.
        _timer?.cancel();
        _timer = null;
      }
    }
  }

  @override
  void dispose() {
    // Обязательно освобождаем таймер, чтобы не было утечки.
    _timer?.cancel();
    super.dispose();
  }

  // ──────────────────────────────── Отрисовка ──────────────────────────────

  @override
  Widget build(BuildContext context) {
    // В анимированном режиме собираем строку: база + N точек + добивка пробелами
    // до maxDots (чтобы ширина не менялась). Иначе — исходный текст как есть.
    final String display = _animated
        ? '$_base${'.' * _count}${' ' * (widget.maxDots - _count)}'
        : widget.text;
    return Text(
      display,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
