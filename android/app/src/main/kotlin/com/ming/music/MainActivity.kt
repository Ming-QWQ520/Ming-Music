package com.ming.music

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
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
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 媒体输出弹窗：已连接的蓝牙音频设备名（系统自动路由）
                    "getMediaDevices" -> result.success(bluetoothDeviceNames())
                    // 「管理蓝牙设备」→ 系统蓝牙设置
                    "openBluetoothSettings" -> {
                        try {
                            startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))
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
                    else -> result.notImplemented()
                }
            }
    }

    /** 已连接的蓝牙音频输出设备名称（A2DP / LE / SCO） */
    private fun bluetoothDeviceNames(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            for (d in devices) {
                val isBt = d.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                        d.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                        d.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                if (!isBt) continue
                val name = d.productName?.toString()?.takeIf { it.isNotBlank() }
                    ?: "蓝牙音频设备"
                out.add(mapOf("name" to name, "type" to d.type))
            }
        } catch (e: Exception) {
            Log.w(TAG, "getMediaDevices failed: $e")
        }
        return out
    }

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
}
