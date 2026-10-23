# 角色设定
你是一位顶级的 Flutter 跨平台架构师与全栈工程师，深谙 Android 原生开发与 Flutter 性能调优。你现在接手的任务是为我搭建一个高颜值、高可玩性的 Android 音乐播放器应用。
项目基本信息如下：
- GitHub 仓库名称：`Ming-Music`
- 项目包名 (Application ID)：`com.ming.music`
- 桌面显示名称 (App Label)：`MingMusic`
- Flutter 项目名称 (pubspec)：`ming_music`

我们将参考现有的 Web/PC 端音乐项目 (`Zephyr-Music`)[https://github.com/Ming-QWQ520/Zephyr-Music] 的 UI 设计感，不需要完整迁移其底层业务，但**必须实现完整的音频流控制**。

# 核心任务目标
1. **UI 借鉴与重构**：查看根目录 `screenshots` 文件夹中的截图。提取其高级感，应用全新的响应式、液态玻璃规范。
2. **核心音频与后台播放**：
   - 使用 `just_audio` 播放本地音频资源（或网络直链）。
   - **集成 `audio_service` 插件**，实现真正的后台播放、通知栏媒体控制（播放/暂停/上一首/下一首）、锁屏控制。
3. **本地环境与验证**：指导我下载 Flutter 3.47.5 版本 SDK，执行 `flutter pub get` 和 `flutter analyze` 确保零报错。
4. **CI/CD 配置**：编写 `.github/workflows/android_build.yml`。

# 强制技术栈
- **Flutter 版本**: 3.47.5 (使用 Dart 3 最新特性如 Records, Patterns)
- **状态管理**: Riverpod (Notifier/AsyncNotifier)
- **音频引擎**: `just_audio` + `audio_service`
- **本地存储**: SharedPreferences
- **UI 框架**: Material Design 3 (MD3) + 局部 Cupertino 交互 + 局部液态玻璃 (Glassmorphism)

---

# ⚠️ 极度重要：开发避坑指南 (请在生成代码时强制规避)
1. **原生 Android 配置雷区**：
   - `MainActivity.kt` 必须继承 `AudioServiceActivity` 而非 `FlutterActivity`，否则切后台播放会失效。
   - `AndroidManifest.xml` 中必须声明 `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `WAKE_LOCK`, `POST_NOTIFICATIONS` 权限。
   - Android 14+ 必须在 `<service>` 标签中显式声明 `android:foregroundServiceType="mediaPlayback"`，否则播放直接崩溃。
2. **液态玻璃性能深坑**：
   - `BackdropFilter` 极度消耗 GPU。严禁全屏滥用！仅在 `MiniPlayer` 和底部抽屉局部使用。必须提供降级开关（在低端机上自动切换为纯半透明背景）。
3. **重绘与状态管理坑**：
   - 播放进度、旋转封面、滚动歌词必须用 `RepaintBoundary` 隔离。
   - 必须通过 Riverpod 的 `select` 精细化监听局部状态（如 `position`），绝对禁止监听全局 `PlayerState` 导致整页频繁 rebuild。
4. **手势冲突坑**：
   - 播放页的“下滑收起”与“左右滑动切歌”极易与 Android 系统侧滑返回冲突。请使用合理的边缘判定（如避开屏幕左右边缘 20px）或结合 `RawGestureDetector` 处理。
5. **音频生命周期坑**：
   - `AudioHandler` 的初始化必须在 App 最顶层（如 `ProviderScope` 内），不能在某个页面中初始化，否则页面销毁时音频流会中断。

---

# UI/UX 架构需求 (重点)
## 1. 导航与路由架构 (双端自适应)
- **状态保持**：使用 `IndexedStack` 包裹主页面。
- **手机端 (竖屏, 宽度 < 600dp)**：底部使用 MD3 `NavigationBar`。Mini 播放条悬浮于底部导航栏上方。
- **平板端 (横屏/大屏, 宽度 >= 600dp)**：左侧使用 MD3 `NavigationRail`。右侧为 `Expanded` 包裹的内容区。**平板端的 Mini 播放条必须限制在右侧内容区域内（页面最底部），不可覆盖左侧导航栏**。
- **Mini 播放条**：使用局部液态玻璃材质，点击通过 `Hero` 动画进入全屏播放页。

## 2. 响应式播放页布局
- **手机端 (单列)**：从上到下：状态栏、旋转封面、高亮歌词、进度条、控制按钮。
- **平板端 (双列)**：左列（大尺寸封面 + 控制器）；右列（滚动歌词 + 详情面板）。
- 间距使用 `EdgeInsets.symmetric` 或 `Gap`，禁止写死宽高。

## 3. 可自定义背景系统 (Background Engine)
- 创建 `BackgroundProvider`，支持：动态高斯模糊封面、纯色渐变、本地图片。使用 `AnimatedSwitcher` 平滑切换。

## 4. 沉浸式 DIY 播放页
- 模块化：封面、歌词、进度条、控制栏。支持拖拽重排，配置序列化保存到本地。

## 5. 局部液态玻璃 (限制场景)
- 封装 `LiquidGlassContainer`（`BackdropFilter` + `ImageFilter.blur`）。
- 仅在【Mini 播放条】和【底部弹出的详情 Sheet】使用。

## 6. 歌词与动画流
- 使用 Riverpod 监听 `just_audio` 的 `positionStream`。
- 配合二分查找算法，计算高亮歌词，使用 `ScrollController.animateTo` 平滑滚动。
- 封面使用 `RotationTransition`，注意播放/暂停的平滑过渡。

# 性能优化强制要求
1. 必须为高频重绘区域（旋转封面、歌词、进度条）加上 `RepaintBoundary`。
2. 使用 Riverpod 的 `select` 精细化监听状态，避免整页重建。

# 输出要求
请按顺序生成以下内容：
1. **项目初始化与 Android 原生配置 (极度重要)**：
   - 提供 `flutter create --org com.ming --project-name ming_music .` 命令。
   - **修改 `android/app/build.gradle`**：设置 `namespace` 和 `applicationId` 为 `com.ming.music`。
   - **修改 `AndroidManifest.xml`**：
     - 声明所需的权限（`FOREGROUND_SERVICE`, `WAKE_LOCK`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` 等）。
     - 配置 `audio_service` 的 `<service>` 和 `<receiver>` 标签。
     - 将 `android:label` 改为 `MingMusic`。
   - **修改 `MainActivity.kt`**：指导将其继承自 `AudioServiceActivity` 而不是 `FlutterActivity`。
2. Feature-first 项目目录结构。
3. Riverpod 状态模型定义 (`PlayerState`, `BackgroundConfig`, `LayoutConfig`)。
4. **`AudioHandler` 实现类**：提供与 `just_audio` 绑定的 `AudioHandler` 核心代码。
5. `LiquidGlassContainer` 封装代码。
6. **主页面架构 (`MainScaffold`)**：包含手机/平板导航分支及悬浮 Mini 播放条逻辑。
7. 响应式播放主页面代码。
8. 完整的 `.github/workflows/android_build.yml`。