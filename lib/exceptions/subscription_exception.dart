// ═══════════════════════════════════════════════════════════════════════════
//  SubscriptionException
//  Исключение уровня подписки: ошибки загрузки/разбора подписки
//  и генерации конфигурации.
//
//  Хранит человекочитаемое сообщение и (опционально) исходную причину
//  (originalException) и стек вызовов (stackTrace) для диагностики/логов.
// ═══════════════════════════════════════════════════════════════════════════

/// Исключение, связанное с обработкой подписки (загрузка, разбор, генерация).
class SubscriptionException implements Exception {
  /// Человекочитаемое описание ошибки (показывается пользователю/в логах).
  final String message;

  /// Исходное исключение-причина, если ошибка обёрнута поверх другой.
  final Object? originalException;

  /// Стек вызовов на момент возникновения (для отладки).
  final StackTrace? stackTrace;

  SubscriptionException(
    this.message, {
    this.originalException,
    this.stackTrace,
  });

  /// Текстовое представление: сообщение и, если есть, исходная причина.
  @override
  String toString() {
    if (originalException != null) {
      return '$message (Причина: $originalException)';
    }
    return message;
  }
}
