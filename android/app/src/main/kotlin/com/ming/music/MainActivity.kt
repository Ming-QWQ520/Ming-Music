package com.ming.music

import android.app.AlertDialog
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioProductStrategy
import android.media.MediaRoute2Info
import android.media.MediaRouter2
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

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

        // ---- 启动诊断（灰屏/首帧失败定位，机型适配测试用） ----
        private const val COMPAT_PREFS = "ming_compat"
        private const val KEY_TEXTURE = "render_mode_texture"
        private const val WATCHDOG_MS = 15_000L

        /** 首帧是否已上屏（onFlutterUiDisplayed 置位；静态避免重建丢失） */
        private var firstFrameShown = false
    }

    /** 首帧看门狗句柄（onDestroy 取消，避免泄漏） */
    private var watchdogHandler: Handler? = null

    /**
     * 首帧未上屏时用户可一键切换 TextureView 兼容渲染。
     *
     * FlutterActivity 默认用 SurfaceView 合成；个别 ROM（HarmonyOS/老麒麟
     * 等）在 SurfaceView 合成路径上存在首帧无法上屏的兼容性问题，
     * TextureView 是 Flutter 官方支持的替代渲染模式（RenderMode.TEXTURE），
     * 仅在确认首帧失败后按需启用，不影响正常机型（仍为默认 SurfaceView）。
     */
    override fun getRenderMode(): RenderMode =
        if (getSharedPreferences(COMPAT_PREFS, MODE_PRIVATE)
                .getBoolean(KEY_TEXTURE, false)
        ) {
            // 注意：本版本引擎（3.47.7）枚举常量为小写 texture（二进制核对）
            RenderMode.texture
        } else {
            super.getRenderMode()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            installNativeCrashCapture()
            writeDeviceInfo()
            scheduleFirstFrameWatchdog()
        } catch (_: Throwable) {
            // 诊断兜底自身绝不能影响启动
        }
    }

    override fun onFlutterUiDisplayed() {
        firstFrameShown = true
        super.onFlutterUiDisplayed()
    }

    override fun onDestroy() {
        watchdogHandler?.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    // ---------------------------------------------------------------- 启动诊断

    /**
     * 原生全局未捕获异常捕获：Dart 层钩子看不到 Java/Kotlin 崩溃，
     * 这里写入外部诊断目录 native_crash.log（Dart 侧 Diag.init 下次启动
     * 读取收录；首帧失败时看门狗对话框也会直接展示）。
     */
    private fun installNativeCrashCapture() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                val dir = getExternalFilesDir(null)
                if (dir != null) {
                    val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
                    File(dir, "native_crash.log").writeText(
                        "time=$ts\nthread=${t.name}\n" + Log.getStackTraceString(e)
                    )
                }
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(t, e)
        }
    }

    /** 设备信息落盘（device_info.txt）：用户求援时截图/取文件自证机型 */
    private fun writeDeviceInfo() {
        try {
            val dir = getExternalFilesDir(null) ?: return
            val versionName = try {
                packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
            } catch (_: Exception) {
                "?"
            }
            val mode = if (getSharedPreferences(COMPAT_PREFS, MODE_PRIVATE)
                    .getBoolean(KEY_TEXTURE, false)
                ) "texture" else "surface"
            File(dir, "device_info.txt").writeText(
                buildString {
                    appendLine("model=${Build.MANUFACTURER} ${Build.MODEL}")
                    appendLine("device=${Build.DEVICE} (${Build.PRODUCT})")
                    appendLine("android=${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
                    appendLine("appVersion=$versionName")
                    appendLine("renderMode=$mode")
                }
            )
        } catch (_: Throwable) {
        }
    }

    /**
     * 首帧看门狗：15 秒未上屏 → 弹出【原生】诊断对话框（不依赖 Flutter
     * 渲染，任何首帧故障下都能弹出来），展示 Dart 诊断日志尾部 + 上次
     * 原生崩溃，并提供「切换兼容渲染模式并重启」一键自愈入口。
     */
    private fun scheduleFirstFrameWatchdog() {
        val handler = Handler(Looper.getMainLooper())
        watchdogHandler = handler
        handler.postDelayed({
            try {
                if (firstFrameShown) return@postDelayed
                showWatchdogDialog(buildWatchdogReport())
            } catch (_: Throwable) {
            }
        }, WATCHDOG_MS)
    }

    private fun buildWatchdogReport(): String = buildString {
        appendLine("应用启动后 ${WATCHDOG_MS / 1000} 秒内未渲染出首帧（灰屏）。")
        appendLine()
        appendLine("机型: ${Build.MANUFACTURER} ${Build.MODEL}")
        appendLine("系统: Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        val texture = getSharedPreferences(COMPAT_PREFS, MODE_PRIVATE)
            .getBoolean(KEY_TEXTURE, false)
        appendLine("渲染模式: ${if (texture) "texture（兼容）" else "surface（默认）"}")
        appendLine()
        val dir = getExternalFilesDir(null)
        val diag = dir?.let { File(it, "diag.log") }
        if (diag != null && diag.exists()) {
            appendLine("---- Dart 诊断日志（末尾） ----")
            val lines = diag.readLines().takeLast(14)
            lines.forEach { appendLine(it) }
            appendLine()
        } else {
            appendLine("（未找到 Dart 诊断日志 —— Dart 引擎可能从未启动）")
            appendLine()
        }
        val crash = dir?.let { File(it, "native_crash.log") }
        if (crash != null && crash.exists()) {
            appendLine("---- 上次原生崩溃（头部） ----")
            crash.readLines().take(6).forEach { appendLine(it) }
        }
        appendLine("完整日志: Android/data/$packageName/files/")
    }

    private fun showWatchdogDialog(report: String) {
        val texture = getSharedPreferences(COMPAT_PREFS, MODE_PRIVATE)
            .getBoolean(KEY_TEXTURE, false)
        val builder = AlertDialog.Builder(this)
            .setTitle("MingMusic 启动诊断")
            .setMessage(report)
            .setCancelable(true)
            .setNegativeButton("关闭", null)
        if (!texture) {
            builder.setPositiveButton("切换兼容渲染并重启") { d, _ ->
                d.dismiss()
                try {
                    getSharedPreferences(COMPAT_PREFS, MODE_PRIVATE)
                        .edit().putBoolean(KEY_TEXTURE, true).commit()
                } catch (_: Throwable) {
                }
                recreate()
            }
        }
        builder.show()
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
                    // 联网检测（无网跳过未缓存歌曲提示的判定条件）
                    "isNetworkAvailable" -> result.success(isNetworkAvailable())
                    // 普通系统通知（无网跳歌原因告知；与媒体通知互不干扰）
                    "postStatusNotice" -> {
                        val title = call.argument<String>("title") ?: "MingMusic"
                        val text = call.argument<String>("text") ?: ""
                        result.success(postStatusNotice(title, text))
                    }
                    // 播放页屏幕常亮（设置「播放页始终亮屏」）
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        try {
                            runOnUiThread {
                                val win = window
                                if (on) {
                                    win.addFlags(
                                        android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                                    )
                                } else {
                                    win.clearFlags(
                                        android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                                    )
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
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
     * 输出设备切换（第三次修复：第三次报修「连蓝牙时仍两个都输出」）。
     *
     * logcat 实证旧实现三层全数失败：
     *  - ExoPlayer 反射：`No field pluginMap`（新版 Flutter embedding 已移除
     *    FlutterEngineConnectionRegistry.pluginMap 字段）；
     *  - MediaRouter2：`target route not found`（旧匹配用
     *    `route.id.contains(AudioDeviceInfo.id)` —— MediaRoute2Info.id 是
     *    字符串路由标识，与 AudioDeviceInfo.id 数值毫无关联，必然不匹配）。
     *
     * 新策略（按可靠性排序，任一成功即返回 true，前两层并行都执行）：
     *  ① 策略级路由（API 30+）：AudioManager.setPreferredDeviceForStrategy
     *     直接把 MEDIA 策略的输出锁定到目标设备 —— 系统级、立即对现有
     *     AudioTrack 生效、不依赖任何播放器实例，最可靠；device=null 清除。
     *  ② 播放器级路由：官方 `FlutterEngine.plugins.get()` 定位
     *     JustAudioPlugin（不再反射 pluginMap）→ 对象图搜索 ExoPlayer →
     *     setPreferredAudioDevice。
     *  ③ MediaRouter2 transferTo（API 31+，放宽匹配：类型匹配优先，
     *    deviceId 仅作辅助 —— 不再作为必要条件）。
     *  ④ API < 33 全局 A2DP 开关回落（保留旧行为）。
     */
    private fun setPreferredOutput(mode: String, deviceId: Int?): Boolean {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // 目标 AudioDeviceInfo：null = 跟随系统自动（清除所有偏好）
        val device: AudioDeviceInfo? = when {
            mode == "speaker" -> am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            mode == "bluetooth" -> am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { isBluetoothType(it.type) && (deviceId == null || it.id == deviceId) }
                ?: am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .firstOrNull { isBluetoothType(it.type) }
            else -> null
        }
        var routed = false

        // ① 策略级路由（主策略）：对 usage=MEDIA 的所有 AudioProductStrategy
        //    设置偏好设备；策略偏好立即作用于该策略的全部音轨（含播放中的）。
        //    注意：数值 30 而非 VERSION_CODES.R —— compileSdk 兼容保险（同前例）。
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                var ok = false
                for (s in AudioProductStrategy.getAudioProductStrategies()) {
                    val aa: AudioAttributes? = try { s.audioAttributes } catch (_: Throwable) { null }
                    if (aa == null || aa.usage != AudioAttributes.USAGE_MEDIA) continue
                    try {
                        // device=null 清除偏好（交还系统自动路由）
                        am.setPreferredDeviceForStrategy(s, device)
                        ok = true
                    } catch (t: Throwable) {
                        Log.w(TAG, "strategy ${s.id} routing failed: $t")
                    }
                }
                if (ok) {
                    Log.i(TAG, "setPreferredOutput via Strategy mode=$mode device=${device?.productName}")
                    routed = true
                }
            } catch (t: Throwable) {
                Log.w(TAG, "strategy routing failed: $t")
            }
        }

        // ② 播放器级路由（官方 plugins.get 定位，不再反射 pluginMap）：
        //    配合 Dart 侧切换后重建音频管线，新 AudioTrack 立即按偏好路由。
        val exo = findExoPlayer()
        if (exo != null) {
            try {
                val m = exo.javaClass.getMethod("setPreferredAudioDevice", AudioDeviceInfo::class.java)
                m.invoke(exo, device)
                Log.i(TAG, "setPreferredOutput via ExoPlayer mode=$mode device=${device?.productName}")
                routed = true
            } catch (t: Throwable) {
                Log.w(TAG, "ExoPlayer routing failed: $t")
            }
        }

        // ③ 系统级路由（MediaRouter2，API 31+）：放宽匹配 —— 类型匹配即可，
        //    deviceId 仅用于精确命中（不再作为必要条件，旧匹配必失败）。
        // isSystemRoute() 为 API 31+，守卫取 S
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val router = MediaRouter2.getInstance(this)
                val routes = router.routes
                val candidates = routes.filter { r ->
                    r.isSystemRoute && when (mode) {
                        "speaker" -> r.type == MediaRoute2Info.TYPE_BUILTIN_SPEAKER ||
                                r.id.equals("DEFAULT_ROUTE", ignoreCase = true)
                        "bluetooth" -> r.type == MediaRoute2Info.TYPE_BLUETOOTH_A2DP ||
                                r.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                                r.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                        else -> false // default 模式不走 transferTo（策略①已清除偏好）
                    }
                }
                // 精确：route id 含 deviceId 数值；否则取第一个类型命中
                val target = candidates.firstOrNull { r ->
                    deviceId != null && r.id.contains(deviceId.toString())
                } ?: candidates.firstOrNull()
                if (target != null) {
                    router.transferTo(target)
                    Log.i(TAG, "setPreferredOutput via MediaRouter2 mode=$mode route=${target.name}")
                    routed = true
                } else if (mode != "default") {
                    Log.w(TAG, "MediaRouter2 target route not found for mode=$mode (routes=${routes.map { it.type }})")
                }
            } catch (t: Throwable) {
                Log.w(TAG, "MediaRouter2 routing failed: $t")
            }
        }

        // ④ 全局 A2DP 开关回落（API < 33 且回落场景，保留旧行为）
        if (!routed && Build.VERSION.SDK_INT < 33 && mode != "default") {
            try {
                @Suppress("DEPRECATION")
                am.setBluetoothA2dpOn(mode == "bluetooth")
                Log.i(TAG, "setPreferredOutput via A2DP mode=$mode")
                routed = true
            } catch (t: Throwable) {
                Log.w(TAG, "A2DP routing failed: $t")
            }
        }
        if (!routed) Log.w(TAG, "setPreferredOutput all strategies failed mode=$mode")
        return routed
    }

    /** 联网检测：任一网络可用即视为在线（wifi/蜂窝/以太网） */
    private fun isNetworkAvailable(): Boolean = try {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val net = cm.activeNetwork
            if (net == null) false
            else {
                val caps = cm.getNetworkCapabilities(net)
                caps != null && caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
            }
        } else {
            @Suppress("DEPRECATION")
            cm.activeNetworkInfo?.isConnected == true
        }
    } catch (e: Exception) {
        Log.w(TAG, "isNetworkAvailable failed: $e")
        true
    }

    /** 普通状态通知（无网跳过未缓存歌曲提示）：独立通道，不与媒体通知冲突 */
    private fun postStatusNotice(title: String, text: String): Boolean = try {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val channelId = "ming_status"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                android.app.NotificationChannel(channelId, "播放状态提示", android.app.NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
        var iconRes = applicationContext.resources.getIdentifier("ic_launcher", "mipmap", packageName)
        if (iconRes == 0) {
            iconRes = applicationContext.resources.getIdentifier("ic_launcher", "drawable", packageName)
        }
        if (iconRes == 0) iconRes = android.R.drawable.ic_dialog_info
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this)
        }
        builder.setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(iconRes)
            .setAutoCancel(true)
            .setStyle(android.app.Notification.BigTextStyle().bigText(text))
        nm.notify(1127, builder.build())
        true
    } catch (e: Exception) {
        Log.w(TAG, "postStatusNotice failed: $e")
        false
    }

    /** 定位 just_audio 内部的 ExoPlayer（见 [setPreferredOutput]）。
     *
     * 修复（logcat 实证 `No field pluginMap`）：新版 Flutter embedding 已
     * 移除 FlutterEngineConnectionRegistry.pluginMap 反射入口，改用官方
     * `FlutterEngine.plugins.get(Class)` API 定位 JustAudioPlugin，
     * 之后在插件对象图内做有限深度遍历找 ExoPlayer 实例。
     */
    private fun findExoPlayer(): Any? {
        // FlutterActivity.flutterEngine 为平台可空 getter：空则直接放弃路由
        val engine = flutterEngine ?: return null
        return try {
            @Suppress("UNCHECKED_CAST")
            val jaClass = Class.forName("com.ryanheise.just_audio.JustAudioPlugin")
                as Class<FlutterPlugin>
            val jaPlugin: FlutterPlugin = engine.plugins.get(jaClass) ?: return null
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
