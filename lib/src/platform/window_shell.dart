import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 窗口行为的两个开关。只在 Windows 上有意义，其它平台恒为默认值。
@immutable
class WindowPrefs {
  const WindowPrefs({this.remember = true, this.edgeHide = true});

  /// 记住窗口大小与位置。关掉时 runner 不再用上次的几何。
  final bool remember;

  /// 贴边隐藏（QQ 式）。
  final bool edgeHide;

  WindowPrefs copyWith({bool? remember, bool? edgeHide}) => WindowPrefs(
        remember: remember ?? this.remember,
        edgeHide: edgeHide ?? this.edgeHide,
      );

  @override
  bool operator ==(Object other) =>
      other is WindowPrefs &&
      other.remember == remember &&
      other.edgeHide == edgeHide;

  @override
  int get hashCode => Object.hash(remember, edgeHide);
}

/// 窗口几何 / 贴边隐藏的 Dart 侧接口。
///
/// 真正的实现在 runner（`windows/runner/window_state.cc`、`edge_dock.cc`）：
/// 几何必须在窗口创建**之前**读到，贴边必须在窗口失焦时也轮询全局鼠标，
/// 这两件事 Dart 都做不到。这里只负责把两个开关读回来 / 写下去。
///
/// 其它平台（Android）全部走空实现：不建通道、不抛异常，界面层用
/// [isSupported] 决定要不要显示这张设置卡片。
class WindowShell {
  WindowShell._();

  static const MethodChannel channel = MethodChannel('wxbills/window');

  /// 测试里没有 Windows 平台，用它把界面「当成 Windows」来验。
  @visibleForTesting
  static bool? debugSupportedOverride;

  static bool get isSupported =>
      debugSupportedOverride ?? (!kIsWeb && Platform.isWindows);

  static WindowPrefs _prefs = const WindowPrefs();

  /// 最近一次读到/写入的开关（界面直接用，避免每次 build 都查通道）。
  static WindowPrefs get cached => _prefs;

  /// 从 runner 读回开关。通道不通就保持默认值，**不抛**：
  /// 窗口设置坏掉不该连带把记账挡住。
  static Future<WindowPrefs> load() async {
    if (!isSupported) {
      _prefs = const WindowPrefs();
      return _prefs;
    }
    try {
      final map = await channel.invokeMapMethod<String, Object?>('getPrefs');
      _prefs = WindowPrefs(
        remember: map?['remember'] != false,
        edgeHide: map?['edge'] != false,
      );
    } catch (_) {
      // MissingPluginException（非 Windows 构建 / 测试）、PlatformException（旧 runner）
      _prefs = const WindowPrefs();
    }
    return _prefs;
  }

  /// 写回 runner。返回是否真的写下去了 —— 失败要让界面说一句，
  /// 否则用户会以为开关生效了，重启又弹回来。
  static Future<bool> save(WindowPrefs prefs) async {
    _prefs = prefs;
    if (!isSupported) return false;
    try {
      await channel.invokeMethod<void>('setPrefs', <String, Object?>{
        'remember': prefs.remember,
        'edge': prefs.edgeHide,
      });
      return true;
    } catch (e) {
      debugPrint('窗口设置写入失败：$e');
      return false;
    }
  }

  /// 把窗口贴到屏幕顶部（只有 Windows 有）。
  ///
  /// **这是唯一的贴边入口**：Windows 的 Aero Snap 会在鼠标碰到屏幕顶端时
  /// 直接最大化窗口，所以"拖到顶边"根本走不通，只能由界面点一下。
  static Future<bool> snapToTop() async {
    if (!isSupported) return false;
    try {
      await channel.invokeMethod<void>('snapToTop');
      return true;
    } catch (e) {
      debugPrint('贴到顶部失败：$e');
      return false;
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _prefs = const WindowPrefs();
    debugSupportedOverride = null;
  }
}
