import java.io.File
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // cfluxdo:不接入 Firebase / Crashlytics,崩溃排查走应用内日志导出。
}

fun Properties.readNonBlank(name: String): String? =
    getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }

fun resolveStoreFile(pathValue: String?): File? {
    val normalized = pathValue?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val directFile = File(normalized)
    if (directFile.isAbsolute) {
        return directFile
    }

    val candidates = linkedSetOf(
        file(normalized),
        rootProject.file(normalized),
    )
    return candidates.firstOrNull { it.exists() } ?: candidates.firstOrNull()
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(keystorePropertiesFile.inputStream())
    }
}
val releaseKeyAlias = keystoreProperties.readNonBlank("keyAlias")
val releaseKeyPassword = keystoreProperties.readNonBlank("keyPassword")
val releaseStorePassword = keystoreProperties.readNonBlank("storePassword")
val releaseStoreFile = resolveStoreFile(keystoreProperties.readNonBlank("storeFile"))
val hasReleaseSigning =
    releaseKeyAlias != null &&
    releaseKeyPassword != null &&
    releaseStorePassword != null &&
    releaseStoreFile?.exists() == true
val releaseBuildSigningName = if (hasReleaseSigning) "release" else "debug"

println(
    if (hasReleaseSigning) {
        "Android local signing: using ${releaseStoreFile?.path} for debug/profile/release"
    } else {
        "Android local signing: incomplete config, debug uses default debug signing and profile/release fallback to debug signing"
    }
)

android {
    namespace = "com.github.lingyan000.fluxdo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // cfluxdo 使用独立包名,可与官方 FluxDO 共存安装
        applicationId = "com.github.molchuan.cfbrowser"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // APK 通过 GitHub Releases 直接分发，下载体积比安装后占用更重要：
    // useLegacyPackaging=true 会把 .so 以 deflate 压进 APK，安装时由系统解压。
    // 实测仅压缩 .so 时 arm64 包 105 MB -> 约 61 MB；叠加字体子集后 50 MB。
    // 代价：安装后磁盘占用约等于「压缩 APK + 解压后的 so」，首次启动略慢。
    // 如果以后改走 AAB / Play，可去掉这一行让 Play 自己按设备下发。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                // minSdk ≥ 24 时 AGP 默认只签 v2；部分手机安装器、文件管理器只认
                // META-INF 里的 v1 签名，会把只有 v2 的包显示成「未签名」
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(releaseBuildSigningName)
        }

        debug {
            signingConfig = signingConfigs.getByName(releaseBuildSigningName)
        }

        getByName("profile") {
            signingConfig = signingConfigs.getByName(releaseBuildSigningName)
        }
    }

    // 只保留 App 实际使用的语言资源:App 文案走 slang,不受影响;
    // 这里裁的是 androidx / ML Kit 等库自带的几十种语言 resources。
    androidResources {
        localeFilters += listOf("en", "zh", "zh-rCN", "zh-rTW", "zh-rHK")
    }

    // 显式根据构建目标过滤 ABI，防止第三方原生库引入不需要的架构
    val targetPlatform = project.findProperty("target-platform") as? String
    println("Target Platform: $targetPlatform")
    if (targetPlatform != null) {
        val targetAbi = when (targetPlatform) {
            "android-arm" -> "armeabi-v7a"
            "android-arm64" -> "arm64-v8a"
            "android-x64" -> "x86_64"
            else -> null
        }

        if (targetAbi != null) {
            println("Configuring build for ABI: $targetAbi")
            defaultConfig {
                ndk {
                    abiFilters.add(targetAbi)
                }
            }
            
            // 强制排除非目标架构的 so 文件 (针对不服从 abiFilters 的预编译库)
            packaging {
                jniLibs {
                    val allAbis = listOf("armeabi-v7a", "arm64-v8a", "x86_64", "x86")
                    allAbis.filter { it != targetAbi }.forEach { abi ->
                        excludes.add("lib/$abi/**")
                    }
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Flutter 插件会把 pub 包里 web 专用的 JS / wasm 资产一并打进 APK(约 4 MB),
// Android 上没有任何代码会加载它们。flutter_assets 是在 mergeAssets 之后才由
// copyFlutterAssets<Variant> 拷进输出目录的,AGP 的 ignoreAssetsPattern 管不到,
// 必须直接挂在这个 Copy 任务上。AssetManifest 仍会列出这些路径,无害。
tasks.matching { it.name.startsWith("copyFlutterAssets") }.configureEach {
    (this as? Copy)?.exclude(
        "**/packages/flutter_avif_web/**",          // avif wasm 解码器
        "**/packages/pro_image_editor/lib/web/**",  // web worker + sourcemap
        "**/packages/media_kit/assets/web/**",      // hls.js
        "**/packages/flutter_inappwebview_web/**",
        "**/packages/wakelock_plus/**",             // no_sleep.js
        "**/packages/fluttertoast/**",              // toastify.js / css
    )
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("org.json:json:20240303")
    implementation("androidx.webkit:webkit:1.15.0")
    // 媒体转码(压缩到 4MB):Transformer 走系统 MediaCodec 硬编
    implementation("androidx.media3:media3-transformer:1.10.1")
    implementation("androidx.media3:media3-effect:1.10.1")
    implementation("androidx.media3:media3-common:1.10.1")
}
