#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
// 保持句柄存活到消息循环结束，确保同一 Windows 登录会话仅有一个实例。
HANDLE g_single_instance_mutex = nullptr;

void FocusExistingInstance() {
  // ① 按标题找（新旧两个名字都试）。
  HWND existing = ::FindWindowW(nullptr, L"HoH music");
  if (!existing) {
    existing = ::FindWindowW(nullptr, L"hoh_music");
  }
  // ② 标题找不到就按**窗口类名**找：Flutter runner 的窗口类固定，
  //    这样标题被改过、或窗口被"关闭按钮 → 托盘"隐藏着时也能找到。
  //    （日志里 [WindowFrame] FindWindowW miss + 第二个实例静默退出，
  //      就是旧逻辑只按标题找造成的"再次启动没反应"。）
  if (!existing) {
    existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  }
  if (!existing) return;

  if (::IsIconic(existing)) {
    ::ShowWindow(existing, SW_RESTORE);
  } else {
    // 也能唤回被“关闭按钮 → 托盘”隐藏的主窗口。
    ::ShowWindow(existing, SW_SHOW);
  }
  ::SetForegroundWindow(existing);
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  g_single_instance_mutex =
      ::CreateMutexW(nullptr, FALSE, L"Local\\HoHMusic.SingleInstance");
  if (!g_single_instance_mutex) {
    // 无法建立互斥体时不能悄悄退回多实例运行。
    return EXIT_FAILURE;
  }
  if (g_single_instance_mutex && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    FocusExistingInstance();
    ::CloseHandle(g_single_instance_mutex);
    g_single_instance_mutex = nullptr;
    return EXIT_SUCCESS;
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
  // Windows 语义树隔离在 Flutter 根组件（lib/app.dart）处理；这里保持
  // runner 的默认 accessibility mode，不要强行切换 UIA/IAccessible。

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // 原生 runner 使用标准标题栏窗口，1280×800 是包含原生非客户区的初始外框尺寸。
  Win32Window::Size size(1280, 800);
  // 窗口标题（显示名）。注意区分：
  //   - 这里是给用户看的标题 "HoH music"
  //   - 可执行文件名 / 包名仍是 hoh_music（见 windows/CMakeLists.txt 的 BINARY_NAME）
  // 两者不同是有意的，不要为了"统一"把标识符也改掉。
  if (!window.Create(L"HoH music", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (g_single_instance_mutex) {
    ::CloseHandle(g_single_instance_mutex);
    g_single_instance_mutex = nullptr;
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
