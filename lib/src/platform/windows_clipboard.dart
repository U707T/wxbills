import 'dart:ffi';
import 'dart:io';

/// 把文件放进 Windows 剪贴板（`CF_HDROP`），效果等同于在资源管理器里「复制」。
///
/// 为什么不用 Flutter 的 `Clipboard.setData`：它只支持文本。而「复制图片」需要
/// 让粘贴目标（微信 / QQ / 资源管理器 / Word）拿到**文件本身**，只能走 Win32。
///
/// 这里直接写 FFI 而不是引 `win32` 包：一共 7 个函数，签名稳定，省一个依赖，
/// 也不受 win32 大版本 API 变动影响（锁定里现在是 6.4.0，随时可能变）。
///
/// 全部调用都在 [Platform.isWindows] 之下，其他平台只会返回 false。
class WindowsClipboard {
  WindowsClipboard._();

  static bool _loaded = false;
  static DynamicLibrary? _user32;
  static DynamicLibrary? _kernel32;

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

  static void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    _user32 = DynamicLibrary.open('user32.dll');
    _kernel32 = DynamicLibrary.open('kernel32.dll');
    _openClipboard =
        _user32!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('OpenClipboard');
    _closeClipboard =
        _user32!.lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
    _emptyClipboard =
        _user32!.lookupFunction<Int32 Function(), int Function()>('EmptyClipboard');
    _setClipboardData = _user32!.lookupFunction<IntPtr Function(Uint32, IntPtr),
        int Function(int, int)>('SetClipboardData');
    _globalAlloc = _kernel32!.lookupFunction<IntPtr Function(Uint32, IntPtr),
        int Function(int, int)>('GlobalAlloc');
    _globalFree =
        _kernel32!.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GlobalFree');
    _globalLock = _kernel32!
        .lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('GlobalLock');
    _globalUnlock = _kernel32!
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('GlobalUnlock');
  }

  /// 复制成功返回 true。
  ///
  /// [path] 必须是**绝对路径**且文件存在；否则粘贴目标会拿到一个坏条目。
  static bool copyFile(String path) {
    if (!Platform.isWindows) return false;
    try {
      _ensureLoaded();
      final file = File(path);
      if (!file.existsSync()) return false;

      // UTF-16LE 内容 + 双 NUL 结尾
      final units = file.absolute.path.codeUnits;
      final bytes = _dropFilesSize + (units.length + 2) * 2;
      final hMem = _globalAlloc(_gmemMoveable | _gmemZeroInit, bytes);
      if (hMem == 0) return false;
      final base = _globalLock(hMem);
      if (base.address == 0) {
        _globalFree(hMem);
        return false;
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

      if (_openClipboard(0) == 0) {
        _globalFree(hMem);
        return false;
      }
      var owned = false;
      try {
        _emptyClipboard();
        owned = _setClipboardData(_cfHDrop, hMem) != 0;
      } finally {
        _closeClipboard();
      }
      // 交出去之后内存归系统所有，不能再 free
      if (!owned) _globalFree(hMem);
      return owned;
    } catch (_) {
      return false;
    }
  }
}
