// ═══════════════════════════════════════════════════════════════════════════
// MemoryOptimizer — возврат рабочего набора процесса системе (только Windows).
//
// Назначение файла:
//   • Возврат физической памяти (рабочего набора) операционной системе, когда
//     окно свёрнуто в трей или минимизировано.
//   • Flutter-движок и Skia удерживают в ОЗУ десятки мегабайт кадровых буферов
//     и арен даже при скрытом окне, когда ничего не рисуется. Вызов WinAPI
//     SetProcessWorkingSetSize(-1, -1) просит Windows вытеснить эти страницы,
//     и потребление в фоне падает до единиц МБ (как в прежних версиях клиента).
//     При возврате окна страницы подгружаются обратно автоматически.
//
// Реализация — прямой вызов kernel32.dll через dart:ffi, без нативных плагинов
// и method-каналов, поэтому модуль самодостаточен. На не-Windows — no-op.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';

// ─── Сигнатуры функций kernel32 ───

/// Нативная сигнатура GetCurrentProcess (возвращает псевдо-HANDLE, равный -1).
typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

/// Нативная сигнатура SetProcessWorkingSetSize(HANDLE, SIZE_T, SIZE_T) -> BOOL.
typedef _SetProcessWorkingSetSizeNative = Int32 Function(
  IntPtr hProcess,
  IntPtr dwMinimumWorkingSetSize,
  IntPtr dwMaximumWorkingSetSize,
);
typedef _SetProcessWorkingSetSizeDart = int Function(
  int hProcess,
  int dwMinimumWorkingSetSize,
  int dwMaximumWorkingSetSize,
);

// ─── Оптимизатор памяти ───

/// Утилита освобождения рабочего набора процесса средствами WinAPI.
class MemoryOptimizer {
  MemoryOptimizer._();

  static bool _resolved = false;
  static _GetCurrentProcessDart? _getCurrentProcess;
  static _SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize;

  /// Лениво находит функции kernel32 один раз за сессию. Любая ошибка просто
  /// отключает оптимизацию (функции остаются null) и не роняет приложение.
  static void _ensureResolved() {
    if (_resolved) return;
    _resolved = true;
    try {
      final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
      _getCurrentProcess = kernel32.lookupFunction<_GetCurrentProcessNative,
          _GetCurrentProcessDart>('GetCurrentProcess');
      _setProcessWorkingSetSize = kernel32.lookupFunction<
          _SetProcessWorkingSetSizeNative,
          _SetProcessWorkingSetSizeDart>('SetProcessWorkingSetSize');
    } catch (e) {
      debugPrint('MemoryOptimizer: не удалось получить функции kernel32: $e');
    }
  }

  /// Просит Windows вернуть рабочий набор процесса системе. На не-Windows —
  /// no-op. Передача -1 в минимальный и максимальный размеры — документированный
  /// способ заставить ОС усечь рабочий набор. Необязательная [delay] позволяет
  /// сначала дать движку освободить кадровые ресурсы после скрытия окна.
  static void trimWorkingSet({Duration delay = Duration.zero}) {
    if (!Platform.isWindows) return;

    void run() {
      _ensureResolved();
      final getProc = _getCurrentProcess;
      final trim = _setProcessWorkingSetSize;
      if (getProc == null || trim == null) return;
      try {
        trim(getProc(), -1, -1);
      } catch (e) {
        debugPrint('MemoryOptimizer: сбой освобождения рабочего набора: $e');
      }
    }

    if (delay == Duration.zero) {
      run();
    } else {
      Timer(delay, run);
    }
  }
}
