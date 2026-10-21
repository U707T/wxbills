import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/store.dart';
import '../../model/bill.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/ui_kit.dart';

/// 设置页：WebDAV 同步 + 文件夹管理 + 数据维护。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late bool _insecure;
  late bool _auto;
  bool _testing = false;
  String _testResult = '';
  bool _showPass = false;
  bool _diagnosing = false;
  String _diagnosis = '';

  /// 用户真的改过表单里的东西才在退出时落盘。
  bool _dirty = false;

  /// WebDAV 填写说明是否展开：默认只在「还没配好」时展开。
  late bool _helpOpen;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final cfg = c.store.sync;
    // 地址框留空，用 hintText 展示默认的坚果云地址。
    // 以前是把默认值直接塞进输入框，再在 dispose 里无条件保存 —— 结果「打开设置
    // 再返回」就等于替用户配好了一个空账号的同步（之后每次改数据都会 401）。
    _url = TextEditingController(text: cfg.url);
    _user = TextEditingController(text: cfg.username);
    _pass = TextEditingController(text: cfg.password);
    _insecure = cfg.allowInsecureTls;
    _auto = cfg.autoSync;
    // 账号密码还没填全 → 说明铺开（用户正在照着填）；已经能用 → 收起
    _helpOpen = cfg.username.isEmpty || cfg.password.isEmpty;
    c.addListener(_onChanged);
    _url.addListener(_onUrlChanged);
  }

  /// 设置页退出时把改动落盘：用户改完开关直接按返回，不点「保存」也不会丢。
  @override
  void dispose() {
    // 只同步内存配置 + 排队落盘，不能 await（dispose 是同步的）。
    // updateSync 内部已经是 unawaited(_persist())。
    _saveQuietlyOnExit();
    c.removeListener(_onChanged);
    _url.removeListener(_onUrlChanged);
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _saveQuietlyOnExit() {
    // 没改过就什么都不写：打开看一眼不该产生任何副作用。
    if (!_dirty) return;
    try {
      final next = SyncConfig(
        url: _url.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
        allowInsecureTls: _insecure,
        autoSync: _auto,
        lastSyncAt: c.store.sync.lastSyncAt,
        lastSyncMessage: c.store.sync.lastSyncMessage,
        lastSyncOk: c.store.sync.lastSyncOk,
      );
      c.saveSyncSilently(next);
    } catch (_) {
      // 退出路径上不要因为保存失败把页面弄崩
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 地址栏内容变化时刷新「用默认地址」按钮的显隐，并记下「改过了」。
  void _onUrlChanged() {
    _dirty = true;
    if (mounted) setState(() {});
  }

  void _save({bool quiet = false}) {
    c.updateSync(SyncConfig(
      url: _url.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      allowInsecureTls: _insecure,
      autoSync: _auto,
      lastSyncAt: c.store.sync.lastSyncAt,
      lastSyncMessage: c.store.sync.lastSyncMessage,
      lastSyncOk: c.store.sync.lastSyncOk,
    ));
    _dirty = false;
    if (!quiet) c.showToast('已保存');
  }

  Future<void> _test() async {
    _save(quiet: true);
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final msg = await c.testSync();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cfg = c.store.sync;
    return Scaffold(
      body: Column(
        children: [
          GreenHeader(
            title: '设置',
            subtitle: 'WebDAV 同步 / 文件夹 / 数据',
            trailing: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close, color: Colors.white, size: 21),
            ),
          ),
          Expanded(
            child: ContentWidth(
              max: 760,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
                children: [
                  _syncCard(cfg),
                  const SizedBox(height: 12),
                  _foldersCard(),
                  const SizedBox(height: 12),
                  _diagnoseCard(),
                  const SizedBox(height: 12),
                  _aboutCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _syncCard(SyncConfig cfg) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_sync_outlined, size: 18, color: Palette.green),
              const SizedBox(width: 8),
              const Text('WebDAV 同步',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (cfg.lastSyncAt > 0)
                Text(
                  '上次 ${_ago(cfg.lastSyncAt)}',
                  style: const TextStyle(fontSize: 11.5, color: Palette.textDim),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 这段「怎么拿应用密码」的说明只在还没配好时铺开；
          // 配好之后收成一行，需要时点「填写说明」再看。
          // 设置页最常被打开的时机是「已经能用、只想改个开关」，
          // 每次都被这一大段文字挤走半屏很碍事。
          if (_helpOpen)
            const Text(
              '默认用坚果云，地址已填好，只需要再填账号和「应用密码」：'
              '坚果云网页版 → 账户信息 → 安全选项 → 添加应用密码（直接用登录密码会 401）。'
              '也可以换成 Nextcloud / Synology 的 WebDAV 地址。\n'
              '「测试连接」会真的去读一次目录，目录不存在会自动建出来，'
              '并把最终路径回显出来——路径通不通，一眼能看到。',
              style: TextStyle(fontSize: 12, height: 1.55, color: Palette.textDim),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _helpOpen = true),
                icon: const Icon(Icons.help_outline, size: 15),
                label: const Text('填写说明（应用密码 / 路径）',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          const SizedBox(height: 14),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              labelText: '服务器地址',
              hintText: kDefaultDavUrl,
              // 地址填成网盘根目录时（坚果云根目录只读），一键回到默认子目录
              suffixIcon: _url.text.trim() == kDefaultDavUrl
                  ? null
                  : TextButton(
                      onPressed: () => setState(() => _url.text = kDefaultDavUrl),
                      child: const Text('用默认', style: TextStyle(fontSize: 12)),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _user,
                  autocorrect: false,
                  onChanged: (_) => _dirty = true,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _pass,
                  obscureText: !_showPass,
                  autocorrect: false,
                  onChanged: (_) => _dirty = true,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    labelText: '密码 / 应用密码',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showPass ? Icons.visibility_off : Icons.visibility,
                        size: 17,
                      ),
                      onPressed: () => setState(() => _showPass = !_showPass),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            value: _insecure,
            onChanged: (v) => setState(() {
              _insecure = v;
              _dirty = true;
            }),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('允许不受信任的证书',
                style: TextStyle(fontSize: 13.5)),
            subtitle: const Text('自签 HTTPS 的 NAS 才需要打开',
                style: TextStyle(fontSize: 11.5, color: Palette.textDim)),
          ),
          SwitchListTile(
            value: _auto,
            onChanged: (v) => setState(() {
              _auto = v;
              _dirty = true;
            }),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('自动同步', style: TextStyle(fontSize: 13.5)),
            subtitle: const Text('启动时、以及修改数据后自动同步一次',
                style: TextStyle(fontSize: 11.5, color: Palette.textDim)),
          ),
          if (cfg.lastSyncMessage.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              cfg.lastSyncMessage,
              // 失败信息用红色：这段是唯一的排错线索，不能和说明文字混在一起
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: cfg.lastSyncOk ? Palette.textDim : Palette.red,
              ),
            ),
          ],
          if (_testResult.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _testResult,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: _testResult.startsWith('连接成功')
                    ? Palette.greenDark
                    : Palette.red,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ActionButton(
                  icon: Icons.save_outlined,
                  label: '保存',
                  onPressed: _save,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ActionButton(
                  icon: Icons.wifi_tethering,
                  label: '测试连接',
                  busy: _testing,
                  onPressed: _test,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ActionButton(
                  icon: Icons.sync_rounded,
                  label: '立即同步',
                  primary: true,
                  busy: c.busy,
                  onPressed: () async {
                    _save(quiet: true);
                    await c.runSync();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _foldersCard() {
    final folders = c.store.folders;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_outlined, size: 18, color: Palette.green),
              const SizedBox(width: 8),
              const Text('图片来源文件夹',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: c.addFolder,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          if (folders.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '还没有导入文件夹。导入存放收款单截图的目录后，会自动识别每张图的金额。',
                style: TextStyle(fontSize: 12, height: 1.55, color: Palette.textDim),
              ),
            )
          else
            for (final f in folders)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  f.isSaf ? Icons.photo_library_outlined : Icons.folder_open,
                  size: 19,
                  color: Palette.textDim,
                ),
                title: Text(f.name, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  f.isSaf ? 'Android 授权目录（SAF）' : f.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Palette.textDim),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  onPressed: () => _confirmRemoveFolder(f.id, f.name),
                ),
              ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: ActionButton(
                  icon: Icons.document_scanner_outlined,
                  label: '增量扫描',
                  onPressed: () => c.scan(force: false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ActionButton(
                  icon: Icons.restart_alt,
                  label: '重新识别全部',
                  onPressed: () => c.scan(force: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 默认关：相册几百上千张，每次打开都比对一遍既慢又没意义。
          // 想要「打开就自动更新」的人自己打开这个开关。
          SwitchListTile(
            value: c.autoScanOnBoot,
            onChanged: (v) => unawaited(c.setAutoScanOnBoot(v)),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('启动时自动扫描', style: TextStyle(fontSize: 13.5)),
            subtitle: Text(
              c.autoScanOnBoot
                  ? '每次打开应用都会扫一遍相册（大相册会慢几秒）'
                  : '已关闭：只在点「扫描识别」时刷新，打开应用更快',
              style: const TextStyle(fontSize: 11.5, color: Palette.textDim),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemoveFolder(String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除文件夹'),
        content: Text('从列表里移除「$name」？\n已识别的收款单记录会保留。',
            style: const TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
        ],
      ),
    );
    if (ok == true) await c.removeFolder(id);
  }

  Future<void> _diagnose() async {
    setState(() {
      _diagnosing = true;
      _diagnosis = '';
    });
    // 跑过一次之后长说明就没用了（下面会收起），记下来省点屏幕
    unawaited(c.markTipSeen(TipKeys.diagnose));
    final text = await c.diagnoseRecognition();
    if (!mounted) return;
    setState(() {
      _diagnosing = false;
      _diagnosis = text;
    });
  }

  /// 识别诊断：扫描后仍是「未识别」时，用它看清卡在读图、解码还是识别。
  Widget _diagnoseCard() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final seen = c.hasSeenTip(TipKeys.diagnose);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.biotech_outlined, size: 18, color: Palette.green),
              SizedBox(width: 8),
              Text('识别诊断',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          // 长说明只看一次：之后收成一行，设置页不再被大段文字占满
          Text(
            seen
                ? '用第一条记录跑一遍，看清卡在读图、解码还是识别。'
                : '扫描后仍是「未识别」时，点下面用第一条记录跑一遍，'
                    '看清是读图失败、解码失败，还是识别不出金额。结果可直接复制。',
            style: const TextStyle(fontSize: 12, height: 1.55, color: Palette.textDim),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ActionButton(
                  icon: Icons.play_circle_outline,
                  label: '诊断第一张图',
                  busy: _diagnosing,
                  onPressed: _diagnose,
                ),
              ),
              if (_diagnosis.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: ActionButton(
                    icon: Icons.copy_all_outlined,
                    label: '复制结果',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _diagnosis));
                      c.showToast('诊断结果已复制');
                    },
                  ),
                ),
              ],
            ],
          ),
          if (_diagnosis.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF262A2C) : const Color(0xFFF4F6F7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _diagnosis,
                style: const TextStyle(fontSize: 11.5, height: 1.55),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _aboutCard() {
    final store = c.store;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: Palette.green),
              SizedBox(width: 8),
              Text('关于',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          _kv('记录数', '${store.count} 条'),
          _kv('合计金额', '¥${Bill.formatCents(store.sumCents)}'),
          _kv('待核对', '${store.reviewCount} 条'),
          _kv('数据文件', store.dirs.dataFile.path),
          const SizedBox(height: 10),
          const Text(
            '识别算法：内置 25px 字形模板匹配（不联网、不上传图片）。'
            '「刷新日期」为 Android 专属功能，用于让 QQ / 相册把旧图当成新图。',
            style: TextStyle(fontSize: 11.5, height: 1.6, color: Palette.textDim),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                await c.resetTips();
                c.showToast('已重置，说明会在下次操作时再出现一次');
              },
              icon: const Icon(Icons.replay_outlined, size: 16),
              label: const Text('重新显示所有说明', style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 74,
              child: Text(k,
                  style: const TextStyle(fontSize: 12.5, color: Palette.textDim)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(fontSize: 12.5, height: 1.4)),
            ),
          ],
        ),
      );

  static String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}
