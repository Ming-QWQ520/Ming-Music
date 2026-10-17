# MingMusic

<div align="center">

**高颜值 · 高可玩性的液态玻璃风格 Android 音乐播放器**

Flutter 3.47.5 · Material Design 3 · Riverpod · just_audio + audio_service

</div>

---

## 项目简介

MingMusic 是一款参考 Zephyr-Music 设计感、面向 Android 的 Flutter 音乐播放器。
它实现了完整的音频流控制（后台播放、通知栏媒体控制、锁屏控制），并采用
**响应式双端布局**（手机 / 平板自适应）、**局部液态玻璃** 与 **可 DIY 的沉浸式播放页**。

核心亮点：

- 🎵 **真后台播放**：`audio_service` 前台服务 + 通知栏/锁屏媒体控制（播放、暂停、上一首、下一首）
- 🪟 **液态玻璃**：`LiquidGlassContainer` 封装（BackdropFilter + ImageFilter.blur），
  仅用于 Mini 播放条与底部详情 Sheet 两处，提供低端机自动降级开关
- 📱 **双端自适应**：手机底部 `NavigationBar` / 平板左侧 `NavigationRail`，
  Mini 播放条位置随端自适应且不覆盖导航
- 🎨 **背景系统**：动态高斯模糊封面 / 5 套纯色渐变 / 本地相册图片，`AnimatedSwitcher` 平滑切换
- 🧩 **DIY 播放页**：封面、歌词、进度条、控制栏四大模块可拖拽重排，配置序列化到本地
- 🎤 **高亮歌词**：LRC 解析（Dart 3 Records）+ 二分查找定位 + `animateTo` 平滑滚动
- 💿 **旋转封面**：`RotationTransition`，暂停冻结角度、恢复无缝续转
- ⚡ **性能自律**：高频区域全部 `RepaintBoundary` 隔离 + Riverpod `select` 精细订阅

## 技术栈

| 维度 | 选型 |
| --- | --- |
| Flutter | 3.47.5 stable（Dart 3，Records / Patterns / Switch Expressions） |
| 状态管理 | flutter_riverpod 2.6.x（Notifier / NotifierProvider） |
| 音频引擎 | just_audio ^0.10 + audio_service ^0.18 |
| 本地存储 | shared_preferences（设置与收藏）+ path_provider（文件缓存） |
| UI | Material Design 3 + 局部 Cupertino 手感 + 局部液态玻璃 |

## 目录结构（Feature-first）

```
Ming-Music/
├── .github/workflows/android_build.yml   # CI：analyze + test + 构建 APK
├── android/                              # flutter create 生成后由覆盖文件修正
├── assets/
│   ├── audio/                            # 内置演示音频（本地合成，可替换）
│   ├── covers/                           # 内置封面
│   └── lyrics/                           # 内置 LRC 歌词
├── lib/
│   ├── main.dart                         # 入口：AudioService.init 在最顶层初始化（避坑 5）
│   ├── app.dart                          # MaterialApp + 主题 + 中文本地化
│   ├── core/
│   │   ├── constants/app_constants.dart  # 全局常量 + 渐变预设（Records）
│   │   ├── storage/prefs_keys.dart       # SharedPreferences 键名注册表
│   │   ├── theme/app_theme.dart          # MD3 主题（亮/暗）
│   │   ├── utils/duration_utils.dart     # 时长格式化扩展
│   │   ├── utils/lyrics.dart             # LRC 解析 + 二分查找
│   │   └── widgets/
│   │       ├── liquid_glass_container.dart # 液态玻璃封装（含降级路径）
│   │       └── cover_image.dart          # 统一封面组件
│   └── features/
│       ├── library/                      # 音乐库：模型 / 仓库 / 收藏 / 页面
│       ├── player/
│       │   ├── domain/player_state.dart  # PlayerState（不可变状态模型）
│       │   ├── services/ming_audio_handler.dart # AudioHandler 核心（避坑 1/5）
│       │   ├── providers/player_providers.dart  # Notifier + 细粒度流
│       │   └── presentation/             # 播放页 + Mini 条 + 各模块 widget
│       ├── settings/                     # 背景系统 / 布局 DIY / 玻璃开关 / 主题
│       └── shell/                        # MainScaffold 双端导航分支
├── test/widget_test.dart                 # LRC/二分查找/格式化/序列化 单元测试
└── tool/
    ├── setup.sh                          # 一键初始化脚本
    └── android_overrides/                # Android 原生配置覆盖文件（避坑 1）
```

## 快速开始

### 1. 安装 Flutter 3.47.5

**方式 A：git 拉取（推荐）**

```bash
git clone -b 3.47.5 --depth 1 https://github.com/flutter/flutter.git ~/flutter-3.47.5
export PATH="$HOME/flutter-3.47.5/bin:$PATH"
```

**方式 B：官方压缩包**

从 https://docs.flutter.dev/release/archive 下载 `flutter_linux_3.47.5-stable.tar.xz`：

```bash
cd ~/ && tar -xf flutter_linux_3.47.5-stable.tar.xz
export PATH="$HOME/flutter/bin:$PATH"
flutter --version   # 确认输出 Flutter 3.47.5
```

**（中国大陆用户）建议先配置镜像：**

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

**依赖检查：**

```bash
flutter doctor
# 需要：Android toolchain（Android Studio + SDK）、JDK 17
```

### 2. 初始化项目（一键脚本）

```bash
cd Ming-Music
chmod +x tool/setup.sh
./tool/setup.sh
```

脚本会依次执行：

1. `flutter create --org com.ming --project-name ming_music --platforms android .`
   生成 gradle wrapper、res、settings 等原生脚手架；
2. 应用 `tool/android_overrides/` 覆盖文件（见下节）；
3. `flutter pub get` && `flutter analyze` && `flutter test`（预期零报错）。

### 3. 运行

```bash
flutter run                # 连接设备或启动模拟器
flutter build apk --release --split-per-abi
```

## Android 原生配置说明（避坑指南 1）

`flutter create --org com.ming` 生成的默认包名是 `com.ming.ming_music`，
且不含媒体播放所需的任何权限/service 配置。`tool/android_overrides/` 提供了
修正后的三个关键文件（setup.sh 会自动覆盖）：

| 文件 | 关键修改 |
| --- | --- |
| `android/app/build.gradle.kts` | `namespace` 与 `applicationId` 改为 `com.ming.music` |
| `android/app/src/main/AndroidManifest.xml` | 声明 `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK` / `POST_NOTIFICATIONS` 权限；注册 `audioservice.AudioService`（**`android:foregroundServiceType="mediaPlayback"`，Android 14+ 必需**）与 `MediaButtonReceiver`；`android:label="MingMusic"` |
| `.../kotlin/com/ming/music/MainActivity.kt` | 继承 **`AudioServiceActivity`**（而非 `FlutterActivity`），否则切后台播放失效 |

同时删除 `flutter create` 生成的错误包路径 `kotlin/com/ming/ming_music/`。

> 手动初始化时，把上述文件按 `tool/android_overrides` 内的相对路径复制即可。

## 架构与避坑对照

| # | 避坑点 | 本项目的落地 |
| --- | --- | --- |
| 1 | 原生配置雷区 | `AudioServiceActivity` 继承、权限/service 声明、foregroundServiceType 均在覆盖文件中固化 |
| 2 | 液态玻璃性能深坑 | 全 App 仅 Mini 播放条与详情 Sheet 两处使用 `BackdropFilter`；背景模糊用 `ImageFiltered`（对源图模糊）；`glassEnabledProvider` + Android 12 以下自动降级纯半透明 |
| 3 | 重绘与状态管理坑 | 进度条/歌词/旋转封面均 `RepaintBoundary` 隔离；UI 一律 `select` 订阅（如 `select((s) => s.playing)`）；进度走独立 `positionProvider` StreamProvider |
| 4 | 手势冲突坑 | 播放页左右滑切歌避开左右边缘 20px（`gestureEdgeExclusion`）；下滑收起使用位移阈值 + 速度阈值双判定 |
| 5 | 音频生命周期坑 | `AudioService.init` 在 `main()` 顶层完成，`audioHandlerProvider.overrideWithValue` 注入全局 `ProviderScope`，与页面生命周期解耦 |

## 后台播放链路

```
main() → AudioService.init(MingAudioHandler)        # 全局唯一实例
       → ProviderScope.overrideWithValue
UI 动作 → PlayerNotifier → MingAudioHandler → just_audio
                     ↓ playbackEventStream
        PlaybackState 广播 → 通知栏媒体控制 / 锁屏
                     ↓ queue / mediaItem
        MediaSession 元数据（标题/歌手/封面）
```

通知栏上一首/下一首被 `PlayerNotifier` 接管（`setSkipHandlers`），
洗牌模式与 App 内按钮行为完全一致。

## CI/CD

`.github/workflows/android_build.yml`：

- 触发：push/PR 到 main、手动 `workflow_dispatch`
- 环境：JDK 17 + `subosito/flutter-action@v2`（flutter-version: 3.47.5，含缓存）
- 步骤：`pub get` → `flutter analyze`（强制零报错）→ `flutter test` → `flutter build apk --release --split-per-abi` → 上传 APK 构件（保留 14 天）

## 内置演示资源说明

`assets/` 内音频为本地合成的原创氛围音乐（占位内容），封面与歌词亦为生成资源，
均可在 `assets/` 中直接替换为真实内容；也可在 App 内通过
「音乐库 → 添加网络直链」挂载任何 http(s) 音频直链（mp3/m4a/flac/aac 等）。

自定义背景选择的本地图片会被拷贝到应用文档目录（`backgrounds/`）持久化，
旧图片自动清理。

## 常见问题

**Q：切后台播放停止 / 通知栏没有控制按钮？**
检查 `MainActivity.kt` 是否继承 `AudioServiceActivity`；确认 Manifest 中
service 声明了 `foregroundServiceType="mediaPlayback"`；Android 13+ 首次启动
需允许通知权限。

**Q：低端机上播放页掉帧？**
设置 → 液态玻璃 → 关闭（或保持「自动」，Android 12 以下会自动降级）。

**Q：`flutter analyze` 报与本地缓存相关的错误？**
执行 `flutter clean && flutter pub get` 后重试。

**Q：想替换内置演示曲目？**
直接替换 `assets/audio/*.mp3` 与 `assets/covers/*.png`，并同步修改
`lib/features/library/domain/track.dart` 中 `kBuiltinTracks` 的元数据。
