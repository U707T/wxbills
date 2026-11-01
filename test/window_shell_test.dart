import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/platform/window_shell.dart';

/// 窗口开关的通道层。真机上它是 `MethodChannel('wxbills/window')`，
/// 由 `windows/runner/flutter_window.cpp` 接住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void handle(Future<Object?> Function(MethodCall call)? handler) {
    messenger.setMockMethodCallHandler(WindowShell.channel, handler);
  }

  setUp(() {
    calls.clear();
    WindowShell.resetForTest();
    WindowShell.debugSupportedOverride = true; // 测试跑在 Linux 上
    handle((call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    handle(null);
    WindowShell.resetForTest();
  });

  test('load 把 runner 的开关读回来', () async {
    handle((call) async {
      calls.add(call);
      expect(call.method, 'getPrefs');
      return <String, Object?>{'remember': false, 'edge': true};
    });

    final prefs = await WindowShell.load();

    expect(prefs.remember, isFalse);
    expect(prefs.edgeHide, isTrue);
    expect(WindowShell.cached, prefs);
  });

  test('save 两个开关一起发给原生（不做"只发改过的那个"）', () async {
    final ok = await WindowShell.save(
      const WindowPrefs(remember: true, edgeHide: false),
    );

    expect(ok, isTrue);
    expect(calls.single.method, 'setPrefs');
    expect(calls.single.arguments, <String, Object?>{
      'remember': true,
      'edge': false,
    });
  });

  test('通道不通时保持默认值，不抛异常也不挡记账', () async {
    handle(null); // 相当于 Android / 单元测试环境：没人接这个通道

    final prefs = await WindowShell.load();
    expect(prefs, const WindowPrefs());

    final ok = await WindowShell.save(const WindowPrefs(edgeHide: false));
    expect(ok, isFalse, reason: '写不进去要能返回失败，界面才好提示');
  });

  test('非 Windows 平台完全不碰通道', () async {
    WindowShell.debugSupportedOverride = false;

    expect(
      await WindowShell.save(const WindowPrefs(edgeHide: false)),
      isFalse,
    );
    expect(await WindowShell.snapToTop(), isFalse);
    expect((await WindowShell.load()).edgeHide, isTrue);
    expect(calls, isEmpty, reason: '不该在 Android 上建一个没人接的通道');
  });

  test('snapToTop 把 runner 的结论原样带回来', () async {
    // runner 返回 true：贴上去了，而且鼠标离开会真的收起
    handle((call) async {
      calls.add(call);
      expect(call.method, 'snapToTop');
      return true;
    });
    expect(await WindowShell.snapToTop(), isTrue);

    // 窗口比工作区还高：runner 也只挪位置、不会自动收起，返回 false
    handle((call) async {
      calls.add(call);
      return false;
    });
    expect(await WindowShell.snapToTop(), isFalse);

    // 旧 runner / 通道没返回值：按失败处理，不能假装成功（否则界面会
    // 承诺一个不存在的自动收起）
    handle((call) async {
      calls.add(call);
      return null;
    });
    expect(await WindowShell.snapToTop(), isFalse);
    expect(calls.length, 3);
  });
}
