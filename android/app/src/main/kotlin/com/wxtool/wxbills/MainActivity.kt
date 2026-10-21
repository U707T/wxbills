package com.wxtool.wxbills

import android.content.ContentUris
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * 平台通道 `wxbills/scan`：补足 Flutter 侧做不到的事。
 *
 *  1. `readImage`  —— 把 `content://` 大图**按需下采样**成 RGBA 字节交给 Dart；
 *     `readBytes`  —— 只回原始字节，解码失败时的兜底路线。
 *     Flutter 侧如果直接把 12MP 的图读进内存再解码，既慢又容易 OOM；
 *     这里用 `inSampleSize` 先缩到最长边 ~1600px，单张识别耗时降到几十毫秒。
 *
 *  2. `refreshDate` —— 「刷新日期」：让 QQ / 相册把旧图当成**新增图片**。
 *     逻辑与原单机版 `DateRefresher.kt` 完全一致，按代价从小到大三步走，
 *     每步都回读验证：改媒体库 date_added → 同目录重建文件 → MediaStore 插入新图。
 *
 *  选目录不走这个通道：Android 侧直接用 saf_util 插件，这里不再留一个永远调不到的
 *  `pickFolder` 分支（两套入口只会让人以为它们是两条生效路径）。
 */
class MainActivity : FlutterActivity() {

    private val bg = Executors.newCachedThreadPool()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readImage" -> readImage(call, result)
                    "readBytes" -> readBytes(call, result)
                    "stat" -> stat(call, result)
                    "refreshDate" -> refreshDate(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        bg.shutdownNow()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 读图

    private fun readImage(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val maxDim = call.argument<Int>("maxDim") ?: 1600
        if (uri == null) {
            result.error("bad_args", "缺少 uri", null)
            return
        }
        bg.execute {
            try {
                val bitmap = decodeSampled(uri, maxDim)
                    ?: return@execute post { result.success(null) }
                val w = bitmap.width
                val h = bitmap.height
                val pixels = IntArray(w * h)
                bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
                bitmap.recycle()
                val out = ByteArray(w * h * 4)
                var o = 0
                for (p in pixels) {
                    out[o++] = ((p shr 16) and 0xFF).toByte()
                    out[o++] = ((p shr 8) and 0xFF).toByte()
                    out[o++] = (p and 0xFF).toByte()
                    out[o++] = ((p ushr 24) and 0xFF).toByte()
                }
                post {
                    result.success(
                        mapOf("bytes" to out, "width" to w, "height" to h)
                    )
                }
            } catch (e: Throwable) {
                post { result.error("decode_failed", e.message ?: "解码失败", null) }
            }
        }
    }

    /**
     * 只把原文件字节读回来，不做任何解码。
     *
     * 给 Dart 侧当第二路线：`readImage` 走 BitmapFactory，一旦某个机型 / 某个文件
     * 解码失败，Dart 可以用这条路线拿原始字节自己解，不至于整本账都显示「未识别」。
     */
    private fun readBytes(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null) {
            result.error("bad_args", "缺少 uri", null)
            return
        }
        bg.execute {
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes == null) {
                    post { result.error("read_failed", "打不开文件（可能没有读权限）", null) }
                } else {
                    post { result.success(bytes) }
                }
            } catch (e: Throwable) {
                post { result.error("read_failed", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    /**
     * 只回文件大小，不读内容。
     *
     * 同步上传原图前用它挡 32MB 上限：先 `readBytes` 再判断等于先把几十 MB
     * 读进堆再决定不要，超限的图正好会在最需要保护的时候 OOM。
     */
    private fun stat(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null) {
            result.error("bad_args", "缺少 uri", null)
            return
        }
        bg.execute {
            val size = runCatching {
                contentResolver.query(
                    uri, arrayOf(OpenableColumns.SIZE), null, null, null
                )?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null }
            }.getOrNull() ?: runCatching {
                contentResolver.openAssetFileDescriptor(uri, "r")?.use { fd ->
                    fd.length.takeIf { it >= 0 }
                }
            }.getOrNull()
            post { result.success(size) }
        }
    }

    /** 先只读尺寸再下采样，避免 4000x6000 的图直接把内存打爆 */
    private fun decodeSampled(uri: Uri, maxDim: Int): Bitmap? {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, opts)
        } ?: return null
        val longest = maxOf(opts.outWidth, opts.outHeight)
        if (longest <= 0) return null
        var sample = 1
        while (longest / sample > maxDim) sample *= 2
        val opts2 = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, opts2)
        }
    }

    // ------------------------------------------------------------ 刷新日期

    private fun refreshDate(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val tree = call.argument<String>("treeUri")?.takeIf { it.isNotBlank() }?.let(Uri::parse)
        if (uri == null) {
            result.error("bad_args", "缺少 uri", null)
            return
        }
        bg.execute {
            val outcome = try {
                refresh(uri, tree)
            } catch (e: Throwable) {
                mapOf<String, Any?>(
                    "ok" to false,
                    "message" to ("刷新失败：" + (e.message ?: e.javaClass.simpleName)),
                    "diagnosis" to (e.stackTraceToString().take(1200)),
                )
            }
            post { result.success(outcome) }
        }
    }

    private fun post(block: () -> Unit) = runOnUiThread(block)

    /**
     * 「刷新日期」主流程。返回给 Dart 的 map：
     * ok / newUri（可能变）/ newName / dateAdded / message / diagnosis。
     */
    private fun refresh(uri: Uri, treeUri: Uri?): Map<String, Any?> {
        val resolver = contentResolver
        val name = queryName(uri)
        val nowSec = System.currentTimeMillis() / 1000

        // ---- 路线 0（最优先）：有「所有文件访问权限」时直接改。
        //      这是唯一能 100% 生效的路子：直接改文件 mtime + 直接改 MediaStore 的
        //      date_added/date_modified/date_taken（QQ 判定「新增」看的就是 date_added）。
        if (hasAllFiles()) {
            val path = realPath(uri)
            var fileTouched = false
            if (path != null) {
                fileTouched = runCatching {
                    File(path).setLastModified(nowSec * 1000)
                }.getOrDefault(false)
            }
            val rowId = findMediaIdByPath(path) ?: findMediaId(name)
            if (rowId != null) {
                val row = ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, rowId
                )
                val dbChanged = runCatching {
                    val cv = ContentValues().apply {
                        put(MediaStore.MediaColumns.DATE_ADDED, nowSec)
                        put(MediaStore.MediaColumns.DATE_MODIFIED, nowSec)
                        put(MediaStore.Images.Media.DATE_TAKEN, nowSec * 1000)
                    }
                    resolver.update(row, cv, null, null) > 0
                }.getOrDefault(false)

                if (dbChanged) {
                    if (!fileTouched && path != null) {
                        runCatching { File(path).setLastModified(nowSec * 1000) }
                    }
                    val added = readDate(row, MediaStore.MediaColumns.DATE_ADDED)
                    if (added >= nowSec - 5) {
                        return mapOf(
                            "ok" to true,
                            "newUri" to uri.toString(),
                            "newName" to name,
                            "dateAdded" to added,
                            "message" to "已更新入库时间，QQ/相册会当成新增图片",
                        )
                    }
                }
            }
        }

        // ---- A：直接改媒体库记录（没有全文件权限时的尝试）
        // 优先按绝对路径定位：同名截图在别的目录里时，只按文件名会改错那一张。
        val mediaId = findMediaIdByPath(realPath(uri)) ?: findMediaId(name)
        if (mediaId != null) {
            val row = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId
            )
            val updated = runCatching {
                val cv = ContentValues().apply {
                    put(MediaStore.MediaColumns.DATE_ADDED, nowSec)
                    put(MediaStore.MediaColumns.DATE_MODIFIED, nowSec)
                }
                resolver.update(row, cv, null, null) > 0
            }.getOrDefault(false)

            if (updated) {
                val added = readDate(row, MediaStore.MediaColumns.DATE_ADDED)
                if (added >= nowSec - 3) {
                    rescan(uri, name)
                    return mapOf(
                        "ok" to true,
                        "newUri" to uri.toString(),
                        "newName" to name,
                        "dateAdded" to added,
                        "message" to "已把入库时间改成现在（路径不变）",
                    )
                }
            }
        }

        // ---- 到这里才需要文件内容：路线 0 与 A 只改时间戳/媒体库记录，
        //      以前一进函数就把整张原图读进内存，成功走前两条路线时那几十 MB 白读。
        val bytes = try {
            resolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Throwable) {
            null
        } ?: return mapOf(
            "ok" to false,
            "message" to "读不到原图（可能没有读权限）",
        )
        if (bytes.isEmpty()) {
            return mapOf("ok" to false, "message" to "原图是空的，已跳过")
        }

        // ---- B：重新造一个新文件（新 _ID → date_added 天然是现在）
        if (treeUri != null) {
            val made = recreateAsNewFile(uri, treeUri, name, bytes)
            if (made != null) {
                rescan(made, name)
                val id = findMediaId(name)
                val added = if (id != null) readDate(
                    ContentUris.withAppendedId(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
                    ),
                    MediaStore.MediaColumns.DATE_ADDED
                ) else 0L
                return mapOf(
                    "ok" to true,
                    "newUri" to made.toString(),
                    "newName" to name,
                    "dateAdded" to added,
                    "message" to "已重建为新图片，QQ/相册会当成新增",
                )
            }
        }

        // ---- B2：目录不让新建文件时，改用 MediaStore 插入一张全新图片。
        //      这条路线不需要「目录可写」，只需要我们有权创建自己的媒体记录。
        val inserted = recreateViaMediaStore(uri, name, bytes)
        if (inserted != null) {
            // 记录里的 path 必须和扫描时 SAF 列出来的文档 URI 一致，否则下一次扫描会
            // 认为这条记录的原文件消失了（打墓碑 + 新建一条重复记录）。
            // 拿不到 SAF 路径就回滚这张新图、保留原图：宁可报失败，也不留半截状态。
            val safUri = treeUri?.let { findSafDoc(it, inserted.second) }
            if (safUri == null) {
                runCatching { contentResolver.delete(inserted.first, null, null) }
                return mapOf(
                    "ok" to false,
                    "message" to "新图已建好但无法定位到 SAF 路径，已回滚（原图未改动）",
                )
            }
            runCatching { DocumentsContract.deleteDocument(contentResolver, uri) }
            val id = findMediaId(inserted.second)
            val added = if (id != null) readDate(
                ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
                ),
                MediaStore.MediaColumns.DATE_ADDED
            ) else 0L
            return mapOf(
                "ok" to true,
                "newUri" to safUri.toString(),
                "newName" to inserted.second,
                "dateAdded" to added,
                "message" to "已重建为新图片（${inserted.second}）",
            )
        }

        // ---- C：连新图都建不了，只能如实报告失败。
        //      绝不能为了改时间戳去 openOutputStream("wt") 重写原图：那是截断后写入，
        //      中途失败就把用户相册里的原始凭证毁成半截文件。
        rescan(uri, name)
        val diag = buildString {
            append("全文件权限=").append(if (hasAllFiles()) "有" else "无")
            append("; 读图=OK（${bytes.size} 字节）")
            append("; 媒体库记录=")
            append(
                when {
                    findMediaIdByPath(realPath(uri)) != null -> "按路径找到"
                    findMediaId(name) != null -> "按文件名找到"
                    else -> "查不到（可能缺 READ_MEDIA_IMAGES）"
                }
            )
            append("; 真实路径=").append(realPath(uri) ?: "拿不到")
            append("; 目录可建文件=").append(if (treeUri != null) "试过但失败" else "未提供目录")
        }
        return mapOf(
            "ok" to false,
            "newUri" to uri.toString(),
            "newName" to name,
            "diagnosis" to diag,
            "message" to "刷新失败：请确认已授予「所有文件访问权限」（原图未被改动）",
        )
    }

    /**
     * 在同目录建新文件写入字节，成功后删掉旧文件。
     * 任何一步失败都返回 null 且**不动原文件**，保证不丢数据。
     */
    private fun recreateAsNewFile(
        old: Uri, treeUri: Uri, name: String?, bytes: ByteArray
    ): Uri? = runCatching {
        val resolver = contentResolver
        val docId = DocumentsContract.getDocumentId(treeUri)
        val parentId = runCatching {
            val fileDocId = DocumentsContract.getDocumentId(old)
            val p = fileDocId.substringBeforeLast('/', "")
            if (p.isEmpty()) null else p
        }.getOrNull() ?: docId

        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
        val mime = queryMime(old) ?: "image/png"
        val displayName = uniqueName(name, parentUri)

        var created = DocumentsContract.createDocument(resolver, parentUri, mime, displayName)
        if (created == null) {
            val retryParent = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            created = DocumentsContract.createDocument(resolver, retryParent, mime, displayName)
        }
        val target: Uri = created ?: return@runCatching null

        val written = runCatching {
            resolver.openOutputStream(target, "wt")?.use { it.write(bytes) } != null
        }.getOrDefault(false)

        if (!written) {
            runCatching { DocumentsContract.deleteDocument(resolver, target) }
            return@runCatching null
        }

        // 新文件写成功才删旧的（保证任何一步失败都不丢数据）
        runCatching { DocumentsContract.deleteDocument(resolver, old) }
        target
    }.getOrNull()

    /** 同名已存在时生成 a_r.png / a_r2.png */
    private fun uniqueName(name: String?, parent: Uri): String {
        val n = name ?: "bill_${System.currentTimeMillis()}.png"
        if (!existsIn(parent, n)) return n
        val dot = n.lastIndexOf('.')
        val base = if (dot > 0) n.substring(0, dot) else n
        val ext = if (dot > 0) n.substring(dot) else ""
        for (i in 1..50) {
            val candidate = "${base}_r" + (if (i == 1) "" else "$i") + ext
            if (!existsIn(parent, candidate)) return candidate
        }
        return "${base}_${System.currentTimeMillis()}$ext"
    }

    private fun existsIn(parent: Uri, name: String): Boolean = runCatching {
        contentResolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(
                parent, DocumentsContract.getDocumentId(parent)
            ),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null
        )?.use { c ->
            while (c.moveToNext()) if (c.getString(0) == name) return true
            false
        } ?: false
    }.getOrDefault(false)

    /**
     * 通过 MediaStore 在同一个相册目录里插入一张**全新图片**（内容就是原图字节）。
     * 新记录 date_added 天然是现在，QQ/相册必然当成新图；也不需要目录的写权限。
     */
    private fun recreateViaMediaStore(
        old: Uri, name: String?, bytes: ByteArray
    ): Pair<Uri, String>? = runCatching {
        val resolver = contentResolver
        val mime = queryMime(old) ?: "image/png"
        val relDir = relativeDir(old) ?: Environment.DIRECTORY_PICTURES
        val newName = uniqueMediaName(name, mime)
        val now = System.currentTimeMillis()

        val cv = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, newName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relDir)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            put(MediaStore.MediaColumns.DATE_ADDED, now / 1000)
            put(MediaStore.MediaColumns.DATE_MODIFIED, now / 1000)
        }
        val target = resolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv
        ) ?: return@runCatching null

        val wrote = runCatching {
            resolver.openOutputStream(target, "wt")?.use { it.write(bytes) } != null
        }.getOrDefault(false)
        if (!wrote) {
            runCatching { resolver.delete(target, null, null) }
            return@runCatching null
        }
        val publish = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
        resolver.update(target, publish, null, null)

        val actual = runCatching {
            resolver.query(target, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else newName }
        }.getOrNull() ?: newName
        target to actual
    }.getOrNull()

    /** SAF docId -> 相册相对目录，如 "Pictures/SKM" */
    private fun relativeDir(old: Uri): String? = runCatching {
        val id = DocumentsContract.getDocumentId(old)
        val rel = id.substringAfter(':', "")
        val dir = rel.substringBeforeLast('/', "")
        if (dir.isEmpty()) null else dir
    }.getOrNull()

    private fun uniqueMediaName(name: String?, mime: String): String {
        val ext = when {
            mime.contains("jpeg") -> ".jpg"
            mime.contains("webp") -> ".webp"
            else -> ".png"
        }
        val base = (name ?: "bill").substringBeforeLast('.', name ?: "bill")
        return "${base}_r${ext}"
    }

    /** 在 SAF 目录里按文件名找新插入的文档，返回它的 document URI */
    private fun findSafDoc(treeUri: Uri, displayName: String): Uri? = runCatching {
        val queue = ArrayDeque<String>()
        queue.add(DocumentsContract.getTreeDocumentId(treeUri))
        var depth = 0
        while (queue.isNotEmpty() && depth <= 2) {
            var levelSize = queue.size
            while (levelSize-- > 0) {
                val parentId = queue.removeFirst()
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
                contentResolver.query(
                    children,
                    arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE
                    ), null, null, null
                )?.use { c ->
                    while (c.moveToNext()) {
                        val id = c.getString(0) ?: continue
                        val nm = c.getString(1)
                        val mt = c.getString(2) ?: ""
                        if (nm == displayName) {
                            return@runCatching DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                        }
                        if (mt == DocumentsContract.Document.MIME_TYPE_DIR) queue.add(id)
                    }
                }
            }
            depth++
        }
        null
    }.getOrNull()

    // ------------------------------------------------------------ 辅助

    private fun hasAllFiles(): Boolean =
        Build.VERSION.SDK_INT < 30 || Environment.isExternalStorageManager()

    /** 用绝对路径精确定位媒体库记录（比按文件名匹配可靠，避免同名图误伤） */
    private fun findMediaIdByPath(path: String?): Long? {
        if (path.isNullOrBlank()) return null
        return runCatching {
            contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DATA} = ?", arrayOf(path),
                "${MediaStore.MediaColumns._ID} DESC"
            )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
        }.getOrNull()
    }

    private fun findMediaId(name: String?): Long? {
        if (name.isNullOrBlank()) return null
        return runCatching {
            contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ?", arrayOf(name),
                "${MediaStore.MediaColumns._ID} DESC"
            )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
        }.getOrNull()
    }

    private fun readDate(row: Uri, column: String): Long = runCatching {
        contentResolver.query(row, arrayOf(column), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else 0L
        } ?: 0L
    }.getOrDefault(0L)

    private fun rescan(uri: Uri, name: String?) {
        val path = realPath(uri)
        if (path != null && File(path).exists()) {
            runCatching { MediaScannerConnection.scanFile(this, arrayOf(path), null, null) }
            return
        }
        if (!name.isNullOrBlank()) {
            val id = findMediaId(name) ?: return
            val row = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
            )
            runCatching {
                val now = System.currentTimeMillis() / 1000
                val cv = ContentValues().apply {
                    put(MediaStore.MediaColumns.DATE_MODIFIED, now)
                }
                contentResolver.update(row, cv, null, null)
            }
        }
    }

    private fun realPath(uri: Uri): String? = runCatching {
        val docId = DocumentsContract.getDocumentId(uri)
        val parts = docId.split(':', limit = 2)
        if (parts.size != 2) return null
        val root = when (parts[0]) {
            "primary" -> Environment.getExternalStorageDirectory()
            else -> File("/storage/${parts[0]}")
        }
        File(root, parts[1]).absolutePath
    }.getOrNull()

    private fun queryName(uri: Uri): String? = runCatching {
        contentResolver.query(
            uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    }.getOrNull()

    private fun queryMime(uri: Uri): String? = runCatching {
        contentResolver.query(
            uri, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    }.getOrNull()

    private companion object {
        const val CHANNEL = "wxbills/scan"
    }
}
