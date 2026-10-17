// MingMusic Android 构建配置（Kotlin DSL，与 Flutter 3.47 官方模板一致）
//
// 关键点（避坑指南 1）：
//  - namespace / applicationId 必须为 com.ming.music
//  - compileSdk 使用 flutter.compileSdkVersion（3.47.5 默认 >= 34，满足
//    FOREGROUND_SERVICE_MEDIA_PLAYBACK 对 API 34 的要求）
//  - AGP 9.x 注意：手动应用 kotlin-android 插件 + kotlinOptions 旧 DSL
//    会触发 Kotlin 2.4 的「弃用=错误」脚本编译失败；
//    必须保持模板形态（无 kotlin-android 声明 + 顶层 kotlin.compilerOptions）
plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ming.music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: 发布前替换为你自己的签名配置，release 请勿长期使用 debug 签名
        applicationId = "com.ming.music"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Demo 阶段先使用 debug 签名以便直接安装；
            // 正式发布请创建 keystore 并配置 signingConfig。
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
