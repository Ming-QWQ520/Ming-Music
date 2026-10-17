#!/usr/bin/env bash
# =============================================================
# MingMusic 一键初始化脚本
#
# 用法（在项目根目录执行）:
#   chmod +x tool/setup.sh && ./tool/setup.sh
#
# 步骤:
#   1. flutter create 生成 android 原生脚手架（gradle wrapper / res / settings 等）
#   2. 应用 tool/android_overrides 中的关键覆盖文件
#      （applicationId、AndroidManifest 权限与 service、AudioServiceActivity、图标）
#   3. flutter pub get + flutter analyze + flutter test
# =============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OVR="$ROOT/tool/android_overrides"

echo "==> [1/4] flutter create 生成脚手架..."
flutter create --org com.ming --project-name ming_music --platforms android .

echo "==> [2/4] 应用 Android 覆盖文件 (applicationId / 权限 / AudioServiceActivity / 图标)..."
cp "$OVR/android/app/build.gradle.kts" android/app/build.gradle.kts
cp "$OVR/android/app/src/main/AndroidManifest.xml" android/app/src/main/AndroidManifest.xml
mkdir -p android/app/src/main/kotlin/com/ming/music
cp "$OVR/android/app/src/main/kotlin/com/ming/music/MainActivity.kt" \
   android/app/src/main/kotlin/com/ming/music/MainActivity.kt
# --org com.ming 默认生成的包路径是 com/ming/ming_music，与目标包名不一致，移除
rm -rf android/app/src/main/kotlin/com/ming/ming_music
cp -R "$OVR/android/app/src/main/res/." android/app/src/main/res/

echo "==> [3/4] flutter pub get..."
flutter pub get

echo "==> [4/4] flutter analyze + flutter test..."
flutter analyze
flutter test

echo ""
echo "✅ 初始化完成！运行 flutter run 即可启动 MingMusic。"
