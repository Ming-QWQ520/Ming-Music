# MingMusic ProGuard/R8 保活规则
#
# 平时 release 已显式 isMinifyEnabled=false（见 build.gradle.kts 内注释），
# 本文件仅在将来开启混淆时生效，防止运行时反射/JNI 访问的成员被裁剪。
#
# 历史教训（2026-10 黑屏事故）：
#   AGP 9 默认开启 minify，R8 删除了 shared_preferences 2.5.x
#   JNI 直连路径的 suspend 方法（仅 getInstance 有 @Keep），
#   启动即 NoSuchMethodError 黑屏。

# Flutter 插件全部保活（JNI/反射/平台通道处理器混用，静态分析不可见）
-keep class io.flutter.plugins.** { *; }
-keepclassmembers class io.flutter.plugins.** { *; }

# dart jni 桥接（jnigen 生成代码经 JNI 按签名反射查找方法）
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class jni.** { *; }
-keep class dev.flutter.** { *; }

# Kotlin 协程（suspend 方法签名含 Continuation，由运行时反射构造）
-keep class kotlinx.coroutines.** { *; }
-keepclassmembers class * {
    <init>(...);
}

# audio_service 后台服务与通知回调
-keep class com.ryanheise.audioservice.** { *; }

# 注解与签名信息（@Keep 生效前提）
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
