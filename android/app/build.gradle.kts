// MingMusic Android 构建配置（Kotlin DSL，与 Flutter 3.47 官方模板一致）
//
// 关键点（避坑指南 1）：
//  - namespace / applicationId 必须为 com.ming.music
//  - compileSdk 使用 flutter.compileSdkVersion（3.47.5 默认 >= 34，满足
//    FOREGROUND_SERVICE_MEDIA_PLAYBACK 对 API 34 的要求）
//  - AGP 9.x 注意：手动应用 kotlin-android 插件 + kotlinOptions 旧 DSL
//    会触发 Kotlin 2.4 的「弃用=错误」脚本编译失败；
//    必须保持模板形态（无 kotlin-android 声明 + 顶层 kotlin.compilerOptions）
//  - AGP 9.x 注意：release 默认启用 R8 minify（与 AGP 8 及以前相反）。
//    R8 看不到 JNI 反射调用的方法，会删除 shared_preferences 2.5.x
//    JNI 直连路径的 suspend 方法（getAll/remove/clear…，仅 getInstance
//    被 @Keep 保护），导致启动时 NoSuchMethodError 黑屏。
//    因此必须显式关闭 minify，并保留 proguard-rules.pro 作为将来
//    开启混淆时的插件保活规则。
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
            // AGP 9 默认 minify=true，必须显式关闭：
            // Flutter 生态插件大量依赖运行时反射/JNI（shared_preferences 2.5.x
            // JNI 直连、audio_service 通知栏回调等），无完整 keep 规则集前
            // 开启 R8 会导致运行时 NoSuchMethodError / ClassNotFound。
            isMinifyEnabled = false
            isShrinkResources = false
            // 保险：一旦将来开启 minify，下面的规则保住插件与 JNI 桥接类
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
