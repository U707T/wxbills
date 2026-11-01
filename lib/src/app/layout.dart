import 'package:flutter/widgets.dart';

import '../platform/window_shell.dart';
import 'theme.dart';

/// 窄布局判定：QQ 窄面板那种「只剩一列列表」的排版。
///
/// 只按**宽度**判断，不引入任何「模式」开关：窗口拖窄了就自动变窄布局，
/// 拖宽了自动变回来。但只有桌面端（Windows）才真的会窄到断点以下 ——
/// Android 手机本来就是 360~430dp，再按窄布局收一档只会把中文标签全变成
/// 省略号，所以那里保持原样。
///
/// 为什么不做成 `InheritedWidget`：这里只有一个布尔值，页面本来就要靠
/// `MediaQuery` 随窗口尺寸重建，多一层状态同步反而多一处可能不刷新的地方。
class AppLayout {
  AppLayout._();

  /// 当前窗口是不是窄的。
  static bool isNarrow(BuildContext context) {
    if (!WindowShell.isSupported) return false;
    return MediaQuery.sizeOf(context).width < Dimens.narrowBreakpoint;
  }
}
