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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
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
