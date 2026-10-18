package com.ming.music

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRoute2Info
import android.media.MediaRouter2
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 避坑指南 1（极度重要）：
 * MainActivity 必须继承 [AudioServiceActivity]（它内部继承自 FlutterActivity），
 * 而不是直接继承 FlutterActivity。
 *
 * AudioServiceActivity 负责在 Activity 生命周期中注册/解绑 MediaSession，
 * 缺失它会导致：切后台播放直接失效、通知栏按钮无响应。
 */
class MainActivity : AudioServiceActivity() {
    companion object {
        private const val CHANNEL = "com.ming.music/media"
        private const val TAG = "MediaChannel"

        /** just_audio 插件注册的方法通道名（输出路由反射的入口线索，仅日志用） */
        private const val JA_CHANNEL = "com.ryanheise.just_audio.methods"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 媒体输出弹窗：已连接的蓝牙音频设备（id+名称+类型）
                    "getMediaDevices" -> result.success(mediaOutputDevices())
                    // 「管理蓝牙设备」→ 系统蓝牙设置
                    "openBluetoothSettings" -> {
                        try {
                            startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    // 输出路由：default=系统自动（蓝牙优先）/ speaker=强制扬声器 / bluetooth=强制蓝牙
                    "setAudioOutput" -> {
                        val mode = call.argument<String>("mode") ?: "default"
                        val deviceId = call.argument<Int>("deviceId")
                        result.success(setPreferredOutput(mode, deviceId))
                    }
                    // 封面保存至相册（MediaStore / 公共目录 + 扫描）
                    "saveImage" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val name = call.argument<String>("name") ?: "MingMusic.jpg"
                        val mime = call.argument<String>("mime") ?: "image/jpeg"
                        if (bytes == null) {
                            result.success(false)
                        } else {
                            result.success(saveImageToGallery(name, mime, bytes))
                        }
                    }
                    // 音频保存至公共音乐目录（歌曲下载 / 设为铃声素材）
                    "saveAudio" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val name = call.argument<String>("name") ?: "song.mp3"
                        val mime = call.argument<String>("mime") ?: "audio/mpeg"
                        if (bytes == null) {
                            result.success(false)
                        } else {
                            result.success(saveAudioToMusic(name, mime, bytes))
                        }
                    }
                    // 本地音乐：MediaStore 音频库扫描
                    "getLocalAudioFiles" -> result.success(localAudioFiles())
                    // 系统分享（歌名/链接）
                    "shareText" -> {
                        val text = call.argument<String>("text") ?: ""
                        try {
                            val intent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(Intent.createChooser(intent, "分享").apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            })
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    // 打开外部链接（问题反馈等）。
                    // 避坑：? 桓表达式与后续语句必须严格分离 —— 历史版本
                    // `?: return@setMethodCallHandler\n result.success(false)` 中
                    // result.success(false) 是孤立语句（url 非空时也会先回复一次），
                    // 导致 Reply already submitted 崩溃（logcat 实证）。
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.success(false)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                })
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------------------------------------------------------------- 输出路由

    /**
     * 输出设备切换：
     * ① 优先 MediaRouter2 系统路由（API 30+，App 级媒体输出，等价系统「媒体输出」面板）；
     * ② 回退反射链定位 ExoPlayer.setPreferredAudioDevice（播放器级路由）。
     * 两者均失败返回 false（UI 回退为「跟随系统自动路由」）。
     */
    private fun setPreferredOutput(mode: String, deviceId: Int?): Boolean {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // 目标 AudioDeviceInfo：null = 跟随系统自动（清除播放器级偏好）
        val device: AudioDeviceInfo? = when {
            mode == "speaker" -> am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            mode == "bluetooth" -> am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { isBluetoothType(it.type) && (deviceId == null || it.id == deviceId) }
            else -> null
        }
        // ① 播放器级路由（反射 ExoPlayer，最直接可靠）
        val exo = findExoPlayer()
        if (exo != null) {
            try {
                val m = exo.javaClass.getMethod("setPreferredAudioDevice", AudioDeviceInfo::class.java)
                m.invoke(exo, device)
                Log.i(TAG, "setPreferredOutput via ExoPlayer mode=$mode device=${device?.productName}")
                return true
            } catch (t: Throwable) {
                Log.w(TAG, "ExoPlayer routing failed: $t")
            }
        }
        // ② 系统级路由（MediaRouter2）：路由整个 App 的媒体输出。
        // isSystemRoute() 为 API 31+，守卫取 S（用户设备 Android 12+）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val router = MediaRouter2.getInstance(this)
                val routes = router.routes
                val target = routes.firstOrNull { r ->
                    r.isSystemRoute && when (mode) {
                        "speaker" -> r.type == MediaRoute2Info.TYPE_BUILTIN_SPEAKER
                        "bluetooth" -> r.type == MediaRoute2Info.TYPE_BLUETOOTH_A2DP ||
                                r.type == MediaRoute2Info.TYPE_BLE_HEADSET ||
                                r.type == MediaRoute2Info.TYPE_BLE_SPEAKER
                        else -> true
                    } && (deviceId == null || r.id.contains(deviceId.toString()))
                }
                if (target != null) {
                    router.transferTo(target)
                    Log.i(TAG, "setPreferredOutput via MediaRouter2 mode=$mode route=${target.name}")
                    return true
                }
                Log.w(TAG, "MediaRouter2 target route not found for mode=$mode")
            } catch (t: Throwable) {
                Log.w(TAG, "MediaRouter2 routing failed: $t")
            }
        }
        Log.w(TAG, "setPreferredOutput all strategies failed mode=$mode")
        return false
    }

    /** 反射定位 just_audio 内部的 ExoPlayer（见 [setPreferredOutput]）。
     *
     * 不依赖固定字段名（just_audio 升级字段可能改名）：在插件对象图内
     * 做有限深度遍历，找到第一个 androidx.media3.exoplayer.ExoPlayer 实例。
     */
    private fun findExoPlayer(): Any? {
        // FlutterActivity.flutterEngine 为平台可空 getter：空则直接放弃路由
        val engine = flutterEngine ?: return null
        return try {
            val registry = engine.javaClass.getMethod("getPlugins").invoke(engine)
            val pluginMapField = registry.javaClass.getDeclaredField("pluginMap").apply {
                isAccessible = true
            }
            @Suppress("UNCHECKED_CAST")
            val pluginMap = pluginMapField.get(registry) as Map<Class<*>, Any>
            val jaPlugin = pluginMap.values.firstOrNull {
                it.javaClass.name.contains("JustAudioPlugin")
            } ?: return null
            searchExoPlayer(jaPlugin, depth = 0)
        } catch (t: Throwable) {
            Log.w(TAG, "findExoPlayer failed: $t")
            null
        }
    }

    /** 在对象图中有限深度搜索 ExoPlayer 实例（字段名无关，版本鲁棒） */
    private fun searchExoPlayer(obj: Any, depth: Int): Any? {
        if (depth > 4) return null
        if (isExoPlayerInstance(obj)) return obj
        for (field in obj.javaClass.declaredFields) {
            if (field.type.isPrimitive || field.type.name.startsWith("java.")) continue
            try {
                field.isAccessible = true
                val v = field.get(obj) ?: continue
                if (isExoPlayerInstance(v)) return v
                // 遍历 Map / 集合容器（just_audio 的 players: Map<String, AudioPlayer>）
                when (v) {
                    is Map<*, *> -> for (item in v.values) {
                        val hit = item?.let { searchExoPlayer(it, depth + 1) }
                        if (hit != null) return hit
                    }
                    is Collection<*> -> for (item in v) {
                        val hit = item?.let { searchExoPlayer(it, depth + 1) }
                        if (hit != null) return hit
                    }
                    else -> {
                        val hit = searchExoPlayer(v, depth + 1)
                        if (hit != null) return hit
                    }
                }
            } catch (_: Throwable) {
                // 单个字段失败继续
            }
        }
        return null
    }

    private fun isExoPlayerInstance(obj: Any): Boolean = try {
        Class.forName("androidx.media3.exoplayer.ExoPlayer").isInstance(obj)
    } catch (_: Throwable) {
        false
    }

    /** 所有可用输出设备（蓝牙 + 本机扬声器），供媒体输出弹窗渲染 */
    private fun mediaOutputDevices(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                val isBt = isBluetoothType(d.type)
                val isSpeaker = d.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                if (!isBt && !isSpeaker) continue
                val name = d.productName?.toString()?.takeIf { it.isNotBlank() }
                    ?: if (isSpeaker) "本机扬声器" else "蓝牙音频设备"
                out.add(
                    mapOf(
                        "name" to name,
                        "type" to d.type,
                        "id" to d.id,
                        "bluetooth" to isBt,
                        "speaker" to isSpeaker,
                    )
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "mediaOutputDevices failed: $e")
        }
        return out
    }

    private fun isBluetoothType(type: Int): Boolean =
        type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
            type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
            type == AudioDeviceInfo.TYPE_BLE_SPEAKER ||
            type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO

    // ---------------------------------------------------------------- 本地音乐

    /** MediaStore 音频库扫描：本地音乐页数据源 */
    private fun localAudioFiles(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        try {
            val collection: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            } else {
                @Suppress("DEPRECATION")
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            }
            val projection = arrayOf(
                MediaStore.Audio.Media._ID,
                MediaStore.Audio.Media.TITLE,
                MediaStore.Audio.Media.ARTIST,
                MediaStore.Audio.Media.ALBUM,
                MediaStore.Audio.Media.DURATION,
                MediaStore.Audio.Media.DATA,
            )
            val selection = "${MediaStore.Audio.Media.DURATION} >= 30000"
            contentResolver.query(collection, projection, selection, null, null)?.use { c ->
                val idC = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val titleC = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistC = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumC = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val durC = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val dataC = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
                while (c.moveToNext()) {
                    out.add(
                        mapOf(
                            "id" to c.getLong(idC),
                            "title" to c.getString(titleC),
                            "artist" to (c.getString(artistC) ?: "未知歌手"),
                            "album" to (c.getString(albumC) ?: "本地音乐"),
                            "duration" to c.getLong(durC),
                            "path" to (c.getString(dataC) ?: ""),
                        )
                    )
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "localAudioFiles failed: $e")
        }
        return out
    }

    // ---------------------------------------------------------------- 保存

    /** 保存图片：API 29+ 走 MediaStore（无需权限）；旧版本公共目录 + 媒体扫描 */
    private fun saveImageToGallery(name: String, mime: String, bytes: ByteArray): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, mime)
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/MingMusic")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri: Uri? = contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                if (uri == null) return false
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                true
            } else {
                @Suppress("DEPRECATION")
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_PICTURES), "MingMusic")
                if (!dir.exists()) dir.mkdirs()
                val file = File(dir, name)
                file.writeBytes(bytes)
                MediaScannerConnection.scanFile(
                    this, arrayOf(file.absolutePath), arrayOf(mime), null)
                true
            }
        } catch (e: Exception) {
            Log.w(TAG, "saveImage failed: $e")
            false
        }
    }

    /** 保存音频：Music/MingMusic（下载歌曲 / 设为铃声） */
    private fun saveAudioToMusic(name: String, mime: String, bytes: ByteArray): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val safeName = if (name.endsWith(".mp3") || name.endsWith(".flac")) name else "$name.mp3"
                val values = ContentValues().apply {
                    put(MediaStore.Audio.Media.DISPLAY_NAME, safeName)
                    put(MediaStore.Audio.Media.MIME_TYPE, mime)
                    put(MediaStore.Audio.Media.RELATIVE_PATH, "Music/MingMusic")
                    put(MediaStore.Audio.Media.IS_PENDING, 1)
                }
                val uri: Uri? = contentResolver.insert(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                if (uri == null) return false
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                values.clear()
                values.put(MediaStore.Audio.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                true
            } else {
                @Suppress("DEPRECATION")
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_MUSIC), "MingMusic")
                if (!dir.exists()) dir.mkdirs()
                val file = File(dir, name)
                file.writeBytes(bytes)
                MediaScannerConnection.scanFile(
                    this, arrayOf(file.absolutePath), arrayOf(mime), null)
                true
            }
        } catch (e: Exception) {
            Log.w(TAG, "saveAudio failed: $e")
            false
        }
    }
}
