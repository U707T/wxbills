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
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(c.toast),
          duration: const Duration(seconds: 3),
        ));
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '收款单管理',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
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
    if (mounted) setState(() {});
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
    if (!widget.controller.ready) {
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
