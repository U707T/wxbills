# 收款单管理（WxBills）

识别微信收款单截图里的金额，按金额排序、快速定位，Android 与 Windows 双端可用，支持 WebDAV 同步。

> 本项目是原 Android 单机版（`wxtool`）的重写：把业务逻辑整体搬到 Flutter，
> 用同一份 Dart 代码同时产出 Android APK 与 Windows 桌面程序，
> 并新增 WebDAV 双向同步（多设备共用一份账）。

## 功能

- **金额识别**：内置 25px 字形模板匹配（专用算法，不是通用 OCR），
  不联网、不上传图片、不依赖任何模型文件。18 张真实收款单回归测试全部正确，
  缩到 50% 仍能识别。
- **按金额排序 / 定位**：金额升序、金额降序、时间倒序、导入倒序；
  输入金额后一键「定位」，列表会滚到对应位置并闪一下。
- **手工确认**：点任意一条改金额与备注，打上「手动」标记；
  之后**重新扫描永远不会覆盖**手工结果（旧版的静默数据丢失问题已修）。
- **待核对提示**：识别成功但置信度不足 84% 的条目标黄，避免错账。
- **WebDAV 同步**：记录 + 缩略图双向同步，支持坚果云 / Nextcloud / Synology 等。
  删除优先：删除会同步（墓碑），且「一台删、另一台改」也会收敛到已删除，不会复活；
  其余冲突按「最后修改时间」合并。
- **刷新图片日期**（Android 专属）：把相册图片的入库时间改成现在，
  让 QQ / 相册把它当成新增图片。走三步兜底策略，失败不丢数据。
- **双端一致**：Windows 上用系统目录对话框选图，Android 上用 SAF 授权目录；
  业务逻辑、界面、同步完全共用一套代码。

## 使用

1. 首次启动点「导入相册」，选一个存放收款单截图的文件夹（可多选目录）。
2. 自动识别金额并按金额升序排列；识别不出的显示「未识别」，点它手动填写。
3. 同步：右上角齿轮 → 填 WebDAV 地址 / 账号 / 密码 → 测试连接 → 立即同步。
   两台设备填同一个地址即可互通。

### 各平台的差异

| 能力 | Android | Windows |
|------|---------|---------|
| 图片来源 | SAF 授权目录（`content://`） | 本地文件夹路径 |
| 金额识别 | 原生下采样 → Dart 模板匹配 | `image` 包解码 → 同一套匹配 |
| 缩略图 | 系统缩略图（最快） | 解码后缩放 |
| 行内快捷操作 | 刷新图片日期 | **复制图片**（原文件进剪贴板） |
| 刷新图片日期 | ✅ | ❌（桌面没有「相册入库时间」概念） |
| WebDAV 同步 | ✅ | ✅ |

## 同步设计

远端目录结构：

```
<你填的地址>/
  bills.json         全部记录（含删除墓碑）的完整快照
  thumbs/<id>.jpg    缩略图
```

- **整份快照 + ETag 条件写**：条数在几百量级，一次 PUT 即可；
  用 `If-Match` / `If-None-Match` 保证并发安全，别人先写了就拿到 412，
  然后重新下载 → 重新合并 → 再写（最多 3 轮）。
- **合并规则**：都没删除时，同一条记录（稳定 id）取 `updatedAt` 更新的；
  时间相同则「有金额 > 无金额」「手动 > 自动」，最终结果与合并顺序无关。
- **删除是墓碑，且删除优先**：`deleted=1` 也会同步；合并时先看删除，
  「A 删除、B 修改」一定收敛到已删除，不会复活。扫描也不会把用户删掉的记录重新捡回来。
- **设备私有字段不合并**：`path` / `folder` 是本机定位，
  从另一台设备同步来的记录不会被本机的路径覆盖，也不会被本机扫描误判为「已删除」。

## 开发

```bash
export PATH=/opt/flutter/bin:$PATH
flutter pub get
flutter analyze
flutter test                      # 66 项：OCR 回归 / 同步端到端 / 存储 / 扫描 / UI / 回归
flutter build apk --debug --target-platform=android-arm64
```

测试覆盖的重点：

| 测试文件 | 覆盖内容 |
|---------|---------|
| `test/amount_reader_test.dart` | 18 张真实收款单 + 50% 缩图 + 空白图 |
| `test/ocr_layout_test.dart` | 金额不在固定高度（状态栏 / 长截图）也要认得出；PNG 字节自解码与桌面路径一致 |
| `test/recognition_retry_test.dart` | 未识别记录会重试、静默扫描不重试、手工金额不被覆盖 |
| `test/sync_test.dart` | 首次上传 / 拉取 / 双向修改 / 删除同步 / ETag 冲突重试 / 401 / 500 / 远端损坏 / 缩略图 |
| `test/sync_nutstore_test.dart` | 坚果云式路径（子目录自建）/ 重复同步 0 PUT / 缩略图只下载一次 / 弱 ETag 不 412 / 测试连接回显路径 |
| `test/store_test.dart` | 金额格式化、合并交换律、原子写、坏文件恢复、墓碑清理 |
| `test/scanner_test.dart` | 增量扫描、手工金额不被覆盖、删除留墓碑、跨设备记录不误删 |
| `test/regression_test.dart` | 列目录失败不误删、删后重扫不复活、并发落盘、定位屏外记录、删除优先合并 |
| `test/boot_sync_test.dart` | 启动时真的会跑一次自动同步（scan 与 sync 不互相抢 _busy） |
| `test/app_ui_test.dart` | 空态、排序、搜索、编辑、删除、设置页 |

同步测试用 `test/support/test_dav_server.dart` 起一个内存 WebDAV 服务器，
不依赖外网，也能注入 412 冲突与 500 故障。

## 目录结构

```
lib/
  main.dart                    启动：解析目录 → 建 store → 渲染 → 加载数据
  src/
    ocr/                       金额识别（纯 Dart，可单测）
      digit_templates.dart     内置字形模板（由原 Kotlin 版机械转换）
      amount_reader.dart       识别算法
    model/bill.dart            记录模型 + 金额格式化 + 合并规则
    data/
      store.dart               本地存储（JSON 快照，原子写）
      scanner.dart             目录扫描 + 增量识别 + 缩略图
      app_dirs.dart            私有目录布局
      json_io.dart             原子写 / 坏文件兜底
    platform/photo_source.dart 平台差异（Android SAF / Windows 文件系统）
    webdav/
      webdav_client.dart       PROPFIND/GET/PUT/MKCOL/HEAD（Basic + 条件写）
      sync.dart                同步引擎（合并 + 墓碑 + 缩略图 + 重试）
    app/                       界面（列表 / 设置 / 主题 / 组件）
android/app/src/main/kotlin/…  MainActivity：下采样解码 + 刷新图片日期
```

## 发布

推送到 `main` 触发 GitHub Actions：测试 → 构建 Android（debug + 分 ABI 的 release）
→ 构建 Windows x64 → 版本号未发过则自动创建 Release。

## 说明

- 识别算法只针对微信收款单的版式（顶部绿底 + 白色卡片 + `¥ XX.XX`）：
  金额所在高度不再写死，截图带状态栏 / 长截图也能认；但**其他 App 的付款截图**
  或整段聊天记录截图仍需要调整字形模板。
- 本应用不收集、不上传任何图片；同步只把你自己的记录与缩略图写到你自己的网盘。
