# MingMusic

<div align="center">

**高颜值 · 高可玩性的液态玻璃风格 Android 音乐播放器**

基于网易云音乐 API · Flutter 3.47.5 · Material Design 3 · Riverpod · just_audio + audio_service

</div>

---

## 项目简介

MingMusic 是一款面向 Android 的 Flutter 在线音乐播放器，接入网易云音乐公开 API，
提供登录账号、搜索、发现推荐、歌单、云盘、本地音乐与一起听等完整体验，并实现了
**真后台播放**（通知栏 / 锁屏媒体控制）与**可深度自定义的沉浸式播放页**。
> [!NOTE]
>提示：本项目目前处于早期测试版，功能正在持续迭代中，如有Bug请即时提Issues</span>

核心亮点：

- 🎵 **真后台播放**：`audio_service` 前台服务 + 通知栏/锁屏媒体控制
  （播放、暂停、上一首、下一首），切歌与队列持久化完整闭环
- 🪟 **液态玻璃**：`LiquidGlassContainer` 封装（BackdropFilter + ImageFilter.blur），
  仅用于 Mini 播放条与底部导航栏两处，提供低端机自动降级开关
- 🎨 **高度自定义播放页**：显示模式 / 封面样式 / 背景模糊与变暗 / 歌词排版与
  逐字着色 / 底部功能条按钮自定义与排序，全部设置实时生效并序列化到本地
- 🎤 **逐字歌词**：yrc 逐词擦除动画 + LRC 回退，支持翻译 / 音译副行、
  双击行 seek、拖动浏览与「时刻保持居中」跟随
- 📱 **双端自适应**：手机底部导航 / 平板左侧 NavigationRail，
  Mini 播放条（经典条 / 紧凑极简两种预设）位置随端自适应
- 🧭 **发现页**：个性化推荐卡带真实歌单封面、每日推荐（可整卡打开歌单详情）、
  私人雷达、私人漫游（自动补歌）、榜单精选可自定义勾选
- 🔍 **全类目搜索**：综合 / 单曲 / 歌单 / 专辑 / 歌手 / MV / 用户 / 歌词
  八类筛选，综合页按官方 order 分区块展示
- 👥 **一起听**：基于网易云官方一起听接口的跨网络房间（创建 / 邀请串加入 /
  播放同步 / 进度对齐 / 成员列表）
- ☁️ **云盘与本地**：登录后自动同步音乐云盘（列表 / 播放 / 删除 / 上传本地音乐）；
  本地音乐 MediaStore 扫描，授权后在我的页显示歌曲总数
- ⚡ **性能自律**：高频区域全部 `RepaintBoundary` 隔离 + Riverpod `select` 精细订阅，
  进度走独立 `positionProvider` StreamProvider

## 技术栈

| 维度 | 选型 |
| --- | --- |
| Flutter | 3.47.5 stable（Dart 3，Records / Patterns / Switch Expressions） |
| 状态管理 | flutter_riverpod 2.6.x（Notifier / NotifierProvider） |
| 音频引擎 | just_audio ^0.10 + audio_service ^0.18 |
| 本地存储 | shared_preferences（设置与队列持久化）+ path_provider（缓存） |
| UI | Material Design 3 + 局部液态玻璃 |

## 目录结构（Feature-first）

```
Ming-Music/
├── .github/workflows/android_build.yml   # CI：analyze + test + 构建 APK
├── android/                              # flutter create 生成后由覆盖文件修正
├── lib/
│   ├── main.dart                         # 入口：AudioService.init 在最顶层初始化
│   ├── app.dart                          # MaterialApp + 主题 + 全局 Mini 条宿主
│   ├── core/
│   │   ├── api/                          # 网易云 API 封装 + 数据模型
│   │   ├── constants/app_constants.dart  # 全局常量
│   │   ├── router.dart                   # go_router 路由表
│   │   ├── storage/prefs_keys.dart       # SharedPreferences 键名注册表
│   │   ├── theme/app_theme.dart          # MD3 主题（亮/暗）
│   │   ├── utils/                        # LRC/yrc 歌词解析、时长格式化等
│   │   └── widgets/                      # 液态玻璃封装、统一封面组件等
│   └── features/
│       ├── auth/                         # 登录（二维码/手机）+ 账号状态
│       ├── discover/                     # 发现页 / 搜索 / 歌单 / 专辑 / 歌手 / MV
│       ├── library/                      # 我的页 / 云盘 / 本地音乐 / 最近播放
│       ├── player/                       # 播放内核 / 播放页 / Mini 条 / 歌词
│       ├── comments/                     # 歌曲评论
│       ├── listen/                       # 一起听（网易云官方接口）
│       ├── settings/                     # 设置页 / 播放页自定义 / 关于
│       └── shell/                        # MainScaffold 双端导航分支
└── test/                                 # 模型 / 序列化 / 解析 单元测试
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

## Android 原生配置说明

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

通知栏上一首/下一首被 `PlayerNotifier` 接管，与 App 内按钮行为完全一致。

## CI/CD

`.github/workflows/android_build.yml`：

- 触发：push/PR 到 main、手动 `workflow_dispatch`
- 环境：JDK 17 + `subosito/flutter-action@v2`（flutter-version: 3.47.5，含缓存）
- 步骤：`pub get` → `flutter analyze`（强制零报错）→ `flutter test` → `flutter build apk --release --split-per-abi` → 上传 APK 构件（保留 14 天）

## 常见问题

**Q：切后台播放停止 / 通知栏没有控制按钮？**
检查 `MainActivity.kt` 是否继承 `AudioServiceActivity`；确认 Manifest 中
service 声明了 `foregroundServiceType="mediaPlayback"`；Android 13+ 首次启动
需允许通知权限。

**Q：低端机上播放页掉帧？**
设置 → 液态玻璃 → 关闭（或保持「自动」，Android 12 以下会自动降级）。

**Q：`flutter analyze` 报与本地缓存相关的错误？**
执行 `flutter clean && flutter pub get` 后重试。

**Q：数据来源与合规说明？**
本应用仅通过网易云音乐公开 API 读取数据，VIP 专属歌曲在未登录状态下仅可
试听或不可播放；项目仅供学习交流，请支持正版音乐。

## 开源协议

本项目基于 **GNU Affero General Public License v3.0（AGPL-3.0）** 开源发布：

- 任何基于本项目的二次开发、分发都必须同样以 AGPL-3.0 开源；
- 通过网络提供服务（含修改版）时，必须向交互用户提供完整的对应源代码；
- 完整协议文本见仓库根目录 [`LICENSE`](./LICENSE)，
  详见 <https://www.gnu.org/licenses/agpl-3.0.html>。
