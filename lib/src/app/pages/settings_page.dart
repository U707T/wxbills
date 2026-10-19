import 'package:flutter/material.dart';

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

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final cfg = c.store.sync;
    _url = TextEditingController(text: cfg.url);
    _user = TextEditingController(text: cfg.username);
    _pass = TextEditingController(text: cfg.password);
    _insecure = cfg.allowInsecureTls;
    _auto = cfg.autoSync;
    c.addListener(_onChanged);
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _save() {
    c.updateSync(SyncConfig(
      url: _url.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      allowInsecureTls: _insecure,
      autoSync: _auto,
      lastSyncAt: c.store.sync.lastSyncAt,
      lastSyncMessage: c.store.sync.lastSyncMessage,
    ));
    c.showToast('已保存');
  }

  Future<void> _test() async {
    _save();
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
          const Text(
            '把收款单记录与缩略图同步到自己的网盘（坚果云 / Nextcloud / Synology 等）。'
            '两台设备填同一个地址即可互通；冲突按「最后修改时间」合并。',
            style: TextStyle(fontSize: 12, height: 1.55, color: Palette.textDim),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'https://dav.jianguoyun.com/dav/wxbills',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _user,
                  autocorrect: false,
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
            onChanged: (v) => setState(() => _insecure = v),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('允许不受信任的证书',
                style: TextStyle(fontSize: 13.5)),
            subtitle: const Text('自签 HTTPS 的 NAS 才需要打开',
                style: TextStyle(fontSize: 11.5, color: Palette.textDim)),
          ),
          SwitchListTile(
            value: _auto,
            onChanged: (v) => setState(() => _auto = v),
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
              style: const TextStyle(fontSize: 11.5, color: Palette.textDim),
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
                    _save();
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
