package com.ming.music

import com.ryanheise.audioservice.AudioServiceActivity

/**
 * 避坑指南 1（极度重要）：
 * MainActivity 必须继承 [AudioServiceActivity]（它内部继承自 FlutterActivity），
 * 而不是直接继承 FlutterActivity。
 *
 * AudioServiceActivity 负责在 Activity 生命周期中注册/解绑 MediaSession，
 * 缺失它会导致：切后台播放直接失效、通知栏按钮无响应。
 */
class MainActivity : AudioServiceActivity()
