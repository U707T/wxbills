#include "window_state.h"

#include <cstdlib>
#include <cstring>

namespace wxb {
namespace {

constexpr wchar_t kAppDirName[] = L"wxbills";
constexpr wchar_t kFileName[] = L"window.ini";
constexpr DWORD kMaxStateBytes = 512;

std::wstring LocalAppDataDir() {
  wchar_t buffer[MAX_PATH] = {0};
  DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    // 服务账户 / 被裁剪的环境变量：退到临时目录，功能照常，只是不跨重启
    length = GetTempPathW(MAX_PATH, buffer);
  }
  if (length == 0) return std::wstring();
  std::wstring dir(buffer, length);
  while (!dir.empty() && (dir.back() == L'\\' || dir.back() == L'/')) {
    dir.pop_back();
  }
  return dir;
}

bool ParseInt(const char* value, int* out) {
  if (value == nullptr || *value == '\0') return false;
  char* end = nullptr;
  const long parsed = std::strtol(value, &end, 10);
  if (end == value) return false;
  // 保存的值是我们自己写的，出现离谱数值只可能是文件被人改过 / 写坏了
  if (parsed < -100000L || parsed > 100000L) return false;
  *out = static_cast<int>(parsed);
  return true;
}

bool ParseBool(const char* value, bool fallback) {
  int parsed = 0;
  if (!ParseInt(value, &parsed)) return fallback;
  return parsed != 0;
}

}  // namespace

std::wstring WindowStateFilePath() {
  const std::wstring base = LocalAppDataDir();
  if (base.empty()) return std::wstring();
  return base + L"\\" + kAppDirName + L"\\" + kFileName;
}

WindowState LoadWindowState() {
  WindowState state;
  const std::wstring path = WindowStateFilePath();
  if (path.empty()) return state;

  const HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return state;

  char buffer[kMaxStateBytes] = {0};
  DWORD read = 0;
  const BOOL ok = ReadFile(file, buffer, kMaxStateBytes - 1, &read, nullptr);
  CloseHandle(file);
  if (!ok || read == 0) return state;
  buffer[read] = '\0';

  int x = 0;
  int y = 0;
  int w = 0;
  int h = 0;
  bool has_x = false;
  bool has_y = false;
  bool has_w = false;
  bool has_h = false;

  // 逐行 key=value。格式是我们自己写的，不做通用 INI 解析。
  char* line = buffer;
  while (line != nullptr && *line != '\0') {
    char* next = std::strchr(line, '\n');
    if (next != nullptr) {
      *next = '\0';
      ++next;
    }
    const char* eq = std::strchr(line, '=');
    if (eq != nullptr) {
      const size_t key_length = static_cast<size_t>(eq - line);
      const char* value = eq + 1;
      if (key_length == 8 && std::strncmp(line, "remember", 8) == 0) {
        state.prefs.remember = ParseBool(value, true);
      } else if (key_length == 4 && std::strncmp(line, "edge", 4) == 0) {
        state.prefs.edge_hide = ParseBool(value, true);
      } else if (key_length == 3 && std::strncmp(line, "max", 3) == 0) {
        state.maximized = ParseBool(value, false);
      } else if (key_length == 1 && line[0] == 'x') {
        has_x = ParseInt(value, &x);
      } else if (key_length == 1 && line[0] == 'y') {
        has_y = ParseInt(value, &y);
      } else if (key_length == 1 && line[0] == 'w') {
        has_w = ParseInt(value, &w);
      } else if (key_length == 1 && line[0] == 'h') {
        has_h = ParseInt(value, &h);
      }
    }
    line = next;
  }

  // 尺寸下限/上限：防止一份坏文件把窗口弄成 10px 或者几十米宽
  if (has_x && has_y && has_w && has_h && w >= 320 && h >= 240 && w <= 20000 &&
      h <= 20000) {
    state.rect.left = x;
    state.rect.top = y;
    state.rect.right = x + w;
    state.rect.bottom = y + h;
    state.valid = true;
  }
  return state;
}

void SaveWindowState(const WindowState& state) {
  const std::wstring path = WindowStateFilePath();
  if (path.empty()) return;

  const size_t slash = path.find_last_of(L'\\');
  if (slash != std::wstring::npos) {
    const std::wstring dir = path.substr(0, slash);
    CreateDirectoryW(dir.c_str(), nullptr);  // 已存在返回 ERROR_ALREADY_EXISTS，忽略
  }

  std::string text;
  text += "remember=";
  text += state.prefs.remember ? "1" : "0";
  text += "\nedge=";
  text += state.prefs.edge_hide ? "1" : "0";
  text += "\nmax=";
  text += state.maximized ? "1" : "0";
  text += "\nx=";
  text += std::to_string(state.rect.left);
  text += "\ny=";
  text += std::to_string(state.rect.top);
  text += "\nw=";
  text += std::to_string(state.rect.right - state.rect.left);
  text += "\nh=";
  text += std::to_string(state.rect.bottom - state.rect.top);
  text += "\n";

  const std::wstring temp_path = path + L".tmp";
  const HANDLE file =
      CreateFileW(temp_path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                  FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  const BOOL ok = WriteFile(file, text.data(),
                            static_cast<DWORD>(text.size()), &written, nullptr);
  CloseHandle(file);
  if (!ok) {
    DeleteFileW(temp_path.c_str());
    return;
  }
  // 关机瞬间被杀：要么旧文件完整，要么新文件完整，不会有半截
  MoveFileExW(temp_path.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
}

}  // namespace wxb
