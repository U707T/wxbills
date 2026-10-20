import 'dart:ffi';
import 'dart:io';

/// 把文件放进 Windows 剪贴板（`CF_HDROP`），效果等同于在资源管理器里「复制」。
///
/// 为什么不用 Flutter 的 `Clipboard.setData`：它只支持文本。而「复制图片」需要
/// 让粘贴目标（微信 / QQ / 资源管理器 / Word）拿到**文件本身**，只能走 Win32。
///
/// 这里直接写 FFI 而不是引 `win32` 包：一共 8 个函数，签名稳定，省一个依赖，
/// 也不受 win32 大版本 API 变动影响（锁定里现在是 6.4.0，随时可能变）。
///
/// 全部调用都在 [Platform.isWindows] 之下，其他平台只会返回 false。
class WindowsClipboard {
  WindowsClipboard._();

  static bool _loaded = false;

  static late final int Function(int) _openClipboard;
  static late final int Function() _closeClipboard;
  static late final int Function() _emptyClipboard;
  static late final int Function(int, int) _setClipboardData;
  static late final int Function(int, int) _globalAlloc;
  static late final int Function(int) _globalFree;
  static late final Pointer<Void> Function(int) _globalLock;
  static late final int Function(int) _globalUnlock;

  // DROPFILES: DWORD pFiles; POINT pt; BOOL fNC; BOOL fWide;  （固定 20 字节）
  static const int _dropFilesSize = 20;
  static const int _cfHDrop = 15;
  static const int _gmemMoveable = 0x0002;
  static const int _gmemZeroInit = 0x0040;

  /// 剪贴板同一时刻只能被一个进程打开。剪贴板管理器、远程桌面、输入法
  /// 都会短暂占用它，所以「OpenClipboard 失败」要重试，不能直接判失败。
  static const int _openAttempts = 6;
  static const Duration _retryDelay = Duration(milliseconds: 40);

  static void _ensureLoaded() {
    if (_loaded) return;
    // 先全部 lookup 成功再置 _loaded：中途抛异常时下次还能重来，
    // 不会留下「_loaded 已经是 true、late final 却没赋值」的半初始化状态。
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final openClipboard =
        user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('OpenClipboard');
    final closeClipboard =
        user32.lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
    final emptyClipboard =
        user32.lookupFunction<Int32 Function(), int Function()>('EmptyClipboard');
    final setClipboardData = user32.lookupFunction<IntPtr Function(Uint32, IntPtr),
        int Function(int, int)>('SetClipboardData');
    final globalAlloc = kernel32.lookupFunction<IntPtr Function(Uint32, IntPtr),
        int Function(int, int)>('GlobalAlloc');
    final globalFree =
        kernel32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GlobalFree');
    final globalLock = kernel32
        .lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('GlobalLock');
    final globalUnlock =
        kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('GlobalUnlock');

    _openClipboard = openClipboard;
    _closeClipboard = closeClipboard;
    _emptyClipboard = emptyClipboard;
    _setClipboardData = setClipboardData;
    _globalAlloc = globalAlloc;
    _globalFree = globalFree;
    _globalLock = globalLock;
    _globalUnlock = globalUnlock;
    _loaded = true;
  }

  /// 复制成功返回 true。
  ///
  /// [path] 必须是**绝对路径**且文件存在；否则粘贴目标会拿到一个坏条目。
  /// 调用方负责先确认文件在（见 `copy_plan.dart`：没有原图时已经换成缩略图）。
  static Future<bool> copyFile(String path) async {
    if (!Platform.isWindows) return false;
    try {
      _ensureLoaded();
      final file = File(path);
      if (!await file.exists()) return false;

      final hMem = _allocDropFiles(file.absolute.path);
      if (hMem == 0) return false;

      for (var attempt = 0; attempt < _openAttempts; attempt++) {
        if (_openClipboard(0) == 0) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        var owned = false;
        try {
          if (_emptyClipboard() != 0) {
            owned = _setClipboardData(_cfHDrop, hMem) != 0;
          }
        } finally {
          _closeClipboard();
        }
        // 交出去之后内存归系统所有，不能再 free
        if (owned) return true;
        await Future<void>.delayed(_retryDelay);
      }
      _globalFree(hMem);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 按 CF_HDROP 的要求拼一块全局内存：`DROPFILES` + UTF-16LE 路径 + 双 NUL。
  /// 返回 HGLOBAL；失败返回 0。
  static int _allocDropFiles(String absolutePath) {
    // Dart 的 String 内部就是 UTF-16，codeUnits 正好是要写进去的 wchar_t 序列
    final units = absolutePath.codeUnits;
    final bytes = _dropFilesSize + (units.length + 2) * 2;
    final hMem = _globalAlloc(_gmemMoveable | _gmemZeroInit, bytes);
    if (hMem == 0) return 0;

    final base = _globalLock(hMem);
    if (base.address == 0) {
      _globalFree(hMem);
      return 0;
    }
    try {
      Pointer<Uint32>.fromAddress(base.address).value = _dropFilesSize; // pFiles
      Pointer<Uint32>.fromAddress(base.address + 16).value = 1; // fWide = TRUE
      final str = Pointer<Uint16>.fromAddress(base.address + _dropFilesSize);
      for (var i = 0; i < units.length; i++) {
        (str + i).value = units[i];
      }
      (str + units.length).value = 0;
      (str + units.length + 1).value = 0;
    } finally {
      _globalUnlock(hMem);
    }
    return hMem;
  }
}
