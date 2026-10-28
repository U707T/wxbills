#include "startup_trace.h"

#include <windows.h>

#include <string>

namespace wxb {
namespace {

bool g_enabled = false;
LARGE_INTEGER g_frequency{};
LARGE_INTEGER g_start{};
DWORD g_pid = 0;

constexpr wchar_t kLogFileName[] = L"wxbills-startup.log";

std::wstring LogPath() {
  wchar_t buffer[MAX_PATH] = {0};
  const DWORD length = GetTempPathW(MAX_PATH, buffer);
  if (length == 0) return std::wstring();
  std::wstring path(buffer, length);
  if (!path.empty() && path.back() != L'\\') path.push_back(L'\\');
  path += kLogFileName;
  return path;
}

std::string Pad2(unsigned int value) {
  if (value < 10) return "0" + std::to_string(value);
  return std::to_string(value);
}

std::string Pad3(unsigned int value) {
  std::string text = std::to_string(value);
  while (text.size() < 3) text.insert(text.begin(), '0');
  return text;
}

void AppendLine(const std::string& line) {
  OutputDebugStringA(line.c_str());
  OutputDebugStringA("\n");

  const std::wstring path = LogPath();
  if (path.empty()) return;
  const HANDLE file =
      CreateFileW(path.c_str(), FILE_APPEND_DATA,
                  FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                  FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
            nullptr);
  WriteFile(file, "\r\n", 2, &written, nullptr);
  CloseHandle(file);
}

}  // namespace

void StartupTraceInit(bool enabled) {
  g_enabled = enabled;
  if (!g_enabled) return;
  if (g_frequency.QuadPart == 0) {
    QueryPerformanceFrequency(&g_frequency);
  }
  QueryPerformanceCounter(&g_start);
  g_pid = GetCurrentProcessId();
}

bool StartupTraceEnabled() { return g_enabled; }

void StartupTraceMark(const char* name) {
  if (!g_enabled || name == nullptr) return;
  LARGE_INTEGER now{};
  QueryPerformanceCounter(&now);
  const double ms =
      g_frequency.QuadPart > 0
          ? static_cast<double>(now.QuadPart - g_start.QuadPart) * 1000.0 /
                static_cast<double>(g_frequency.QuadPart)
          : 0.0;
  SYSTEMTIME local_time{};
  GetLocalTime(&local_time);
  // 只用来和 Dart 侧日志对齐，格式固定，不做本地化
  std::string stamp = Pad2(local_time.wHour);
  stamp += ":";
  stamp += Pad2(local_time.wMinute);
  stamp += ":";
  stamp += Pad2(local_time.wSecond);
  stamp += ".";
  stamp += Pad3(local_time.wMilliseconds);
  std::string line = "native pid=";
  line += std::to_string(g_pid);
  line += " ";
  line += stamp;
  line += " ";
  line += name;
  line += "=";
  line += std::to_string(ms);
  line += "ms";
  AppendLine(line);
}

}  // namespace wxb
