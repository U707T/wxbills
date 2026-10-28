import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'pages/bills_page.dart';
import 'pages/settings_page.dart';
import 'theme.dart';

/// 应用根组件。
class WxBillsApp extends StatefulWidget {
  const WxBillsApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<WxBillsApp> createState() => _WxBillsAppState();
}

class _WxBillsAppState extends State<WxBillsApp> {
  /// 必须用 key 拿 messenger，不能在 build 方法所在的 context 上
  /// `ScaffoldMessenger.maybeOf(context)` —— 那个 context 在 MaterialApp **之上**，
  /// 根本找不到 ScaffoldMessenger，返回 null。之前的写法就是因此让所有
  /// toast（扫描结果、保存失败、复制成功…）静默失效。
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  int _toastSeq = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final c = widget.controller;
    if (!mounted) return;
    if (c.toastSeq != _toastSeq && c.toast.isNotEmpty) {
      _toastSeq = c.toastSeq;
      // 只处理提示，不 setState：这一层没有依赖 controller 的界面，
      // 每来一次通知就整棵树重建一遍纯属浪费（列表自己会重建）。
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(c.toast),
          duration: const Duration(seconds: 3),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '收款单管理',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      scaffoldMessengerKey: _messengerKey,
      home: HomeShell(controller: widget.controller),
    );
  }
}

/// 首页壳：小屏是单页 + 设置用新路由，大屏（Windows）是左右分栏。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ready = widget.controller.ready;
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  /// 这一层只关心「数据是否已就绪」：就绪之后的重建由 BillsPage 自己负责，
  /// 否则每次扫描进度都会把整个 Scaffold 重建一遍。
  void _onChanged() {
    if (!mounted) return;
    if (_ready == widget.controller.ready) return;
    setState(() => _ready = widget.controller.ready);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(controller: widget.controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: _LoadingShell());
    }
    return Scaffold(
      body: SafeArea(
        top: false,
        child: BillsPage(
          controller: widget.controller,
          onOpenSettings: _openSettings,
        ),
      ),
    );
  }
}

/// 首屏骨架：数据还没读出来时，先把「窗口已经起来了」画出来。
///
/// 以前这里只有一个居中转圈：窗口出现 → 一圈灰白 → 列表"啪"地顶上来，
/// 观感上比真实等待更慢，还会闪一下。现在把绿色头部和列表位置直接占住，
/// 数据到达时只换中间那块，没有整页跳动。
class _LoadingShell extends StatelessWidget {
  const _LoadingShell();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? Palette.darkCard : Palette.card;
    return Column(
      children: [
        // 高度与 BillsPage 的 GreenHeader（14+标题+4+副标题+14 ≈ 71）对齐
        Container(
          height: 71 + MediaQuery.of(context).padding.top,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Palette.green, Palette.greenDark],
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
            itemCount: 6,
            physics: const NeverScrollableScrollPhysics(),
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, _) => Container(
              height: 78,
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(Dimens.cardRadius),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
