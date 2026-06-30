import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  AppTheme / kThemeVariants
//  Построение темы Material 3 приложения.
//
//  Тема строится из seed-цвета (ColorScheme.fromSeed) с выбранным вариантом
//  динамической схемы. Поддерживается режим «чистый чёрный» (pureBlack)
//  для OLED-экранов. Шрифт — Inter, переходы страниц — fade-upwards (Windows).
// ═══════════════════════════════════════════════════════════════════════════

/// Сопоставление строковых ключей с вариантами динамической схемы Material 3.
/// Используется в настройках для выбора стиля генерации палитры из seed-цвета.
const Map<String, DynamicSchemeVariant> kThemeVariants = {
  'tonalSpot': DynamicSchemeVariant.tonalSpot,
  'fidelity': DynamicSchemeVariant.fidelity,
  'monochrome': DynamicSchemeVariant.monochrome,
  'neutral': DynamicSchemeVariant.neutral,
  'vibrant': DynamicSchemeVariant.vibrant,
  'expressive': DynamicSchemeVariant.expressive,
  'content': DynamicSchemeVariant.content,
  'rainbow': DynamicSchemeVariant.rainbow,
  'fruitSalad': DynamicSchemeVariant.fruitSalad,
};

/// Фабрика темы приложения (только статические методы; экземпляры не создаются).
class AppTheme {
  /// Приватный конструктор: класс служит пространством имён, создавать его нельзя.
  AppTheme._();

  /// Выбор варианта схемы по ключу; при неизвестном ключе — tonalSpot по умолчанию.
  static DynamicSchemeVariant _variantOf(String key) =>
      kThemeVariants[key] ?? DynamicSchemeVariant.tonalSpot;

  /// Собрать [ThemeData] по яркости, seed-цвету, варианту схемы и флагу pureBlack.
  static ThemeData build({
    required Brightness brightness,
    required Color seed,
    required String variant,
    required bool pureBlack,
  }) {
    final bool isDark = brightness == Brightness.dark;

    // Базовая цветовая схема, сгенерированная из seed-цвета.
    final ColorScheme baseScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: _variantOf(variant),
    );

    ColorScheme scheme = baseScheme;
    Color scaffoldBg;

    if (isDark && pureBlack) {
      // Режим OLED: чистый чёрный фон + почти чёрная поверхность (0xFF0A0A0A).
      scaffoldBg = Colors.black;
      scheme = baseScheme.copyWith(surface: const Color(0xFF0A0A0A));
    } else {
      // Обычный тёмный/светлый фон.
      scaffoldBg = isDark ? const Color(0xFF0D0F11) : const Color(0xFFF8F9FA);
    }

    return ThemeData(
      fontFamily: 'Inter',
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBg,
      // На Windows используем плавный переход fade-upwards между страницами.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder()},
      ),
    );
  }
}
