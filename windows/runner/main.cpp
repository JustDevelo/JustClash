#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <Commctrl.h>
#include <vector>
#include <string>

#include "flutter_window.h"
#include "utils.h"

#pragma comment(lib, "Comctl32.lib")

LRESULT CALLBACK SingleInstanceSubclassProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam, UINT_PTR uIdSubclass, DWORD_PTR dwRefData) {
    static UINT const WM_SHOW_ME_PLEASE = RegisterWindowMessage(L"JustClash_ShowMePlease_Message");
    if (uMsg == WM_SHOW_ME_PLEASE) {
        ShowWindow(hWnd, SW_SHOW);
        ShowWindow(hWnd, SW_RESTORE);
        SetWindowPos(hWnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetForegroundWindow(hWnd);
        SetActiveWindow(hWnd);
        return 0;
    }
    return DefSubclassProc(hWnd, uMsg, wParam, lParam);
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {

  bool isElevated = wcsstr(command_line, L"--elevated") != nullptr;
  HANDLE hMutex = CreateMutex(NULL, TRUE, L"JustClash_SingleInstance_Mutex");
  DWORD lastError = GetLastError();
  
  UINT const WM_SHOW_ME_PLEASE = RegisterWindowMessage(L"JustClash_ShowMePlease_Message");

  if (hMutex == NULL || lastError == ERROR_ALREADY_EXISTS || lastError == ERROR_ACCESS_DENIED) {
      if (isElevated && lastError == ERROR_ALREADY_EXISTS) {
          DWORD waitResult = WaitForSingleObject(hMutex, 1500);
          if (waitResult == WAIT_TIMEOUT || waitResult == WAIT_FAILED) {
              HWND existingWindow = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"JustClash");
              if (existingWindow) {
                  PostMessage(existingWindow, WM_SHOW_ME_PLEASE, 0, 0);
              }
              if (hMutex) CloseHandle(hMutex);
              return 0;
          }
      } else {
          HWND existingWindow = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"JustClash");
          if (existingWindow) {
              PostMessage(existingWindow, WM_SHOW_ME_PLEASE, 0, 0);
          }
          if (hMutex) CloseHandle(hMutex);
          return 0;
      }
  }
  
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"JustClash", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  HWND hwnd = window.GetHandle();
  if (hwnd) {
      ChangeWindowMessageFilterEx(hwnd, WM_SHOW_ME_PLEASE, MSGFLT_ALLOW, NULL);
      SetWindowSubclass(hwnd, SingleInstanceSubclassProc, 1, 0);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();

  if (hMutex) {
    ReleaseMutex(hMutex);
    CloseHandle(hMutex);
  }

  return EXIT_SUCCESS;
}