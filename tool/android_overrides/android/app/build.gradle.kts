// MingMusic Android 构建配置（Kotlin DSL）
//
// 关键点（避坑指南 1）：
//  - namespace / applicationId 必须为 com.ming.music
//  - compileSdk 使用 flutter.compileSdkVersion（3.47.5 默认 >= 34，满足
//    FOREGROUND_SERVICE_MEDIA_PLAYBACK 对 API 34 的要求）
plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ming.music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
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

flutter {
    source = "../.."
}
