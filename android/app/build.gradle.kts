import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
val allowDebugReleaseSigning =
    System.getenv("NEUROMESH_ALLOW_DEBUG_RELEASE_SIGNING") == "true"
val publicTestApk = System.getenv("NEUROMESH_PUBLIC_TEST_APK") == "true"
if (publicTestApk && gradle.startParameter.taskNames.any {
        it.substringAfterLast(':').startsWith("bundle", ignoreCase = true)
    }) {
    throw GradleException("The public test signer is only for standalone APKs.")
}
val isReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (isReleaseBuild && !hasReleaseKeystore && !allowDebugReleaseSigning) {
    throw GradleException(
        "Release signing is not configured. Add android/key.properties using " +
            "android/key.properties.example. Do not publish an APK signed with a debug key."
    )
}

if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
}

android {
    namespace = "com.neuromesh.ai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    packaging {
        jniLibs {
            // llama.cpp armv9 (SVE2/SME) CPU variants abort on some phones
            // (Pixel 8); the loader never picks them, so don't ship them.
            excludes += setOf("**/libggml-cpu-android_armv9*.so")
            if (System.getenv("NEUROMESH_PLAY_BUNDLE") == "true") {
                excludes += setOf(
                    "**/libproot.so",
                    "**/libproot_loader.so",
                    "**/libtalloc.so",
                    "**/libandroid-shmem.so",
                )
            }
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = if (publicTestApk) "com.neuromesh.ai.test" else "com.neuromesh.ai"
        manifestPlaceholders["neuromeshAppLabel"] =
            if (publicTestApk) "NeuroMesh AI Test" else "NeuroMesh AI"
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }


    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Keep the upload bundle small. The native libraries still ship,
            // while AGP's duplicate symbol files stay out of the bundle.
            ndk.debugSymbolLevel = "NONE"
            // Flutter supplies ABI defaults on build types, which override
            // defaultConfig. Replace those defaults only for the ARM64 APK;
            // AAB builds retain the full supported ABI set.
            if (System.getenv("NEUROMESH_ARM64_APK_ONLY") == "true") {
                ndk.abiFilters.clear()
                ndk.abiFilters.add("arm64-v8a")
            }
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

// Flutter 3.38 copies dependency assets marked platforms: [web] into Android
// releases. These packages use native libraries and assets on Android.
tasks.withType<Copy>().matching { it.name == "copyFlutterAssetsRelease" }.configureEach {
    exclude(
        "flutter_assets/packages/piper_phonemize/assets/web/piper-phonemize-wasm-main.data",
        "flutter_assets/packages/sherpa_onnx_web/assets/sherpa-onnx-wasm-web.wasm",
    )
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.documentfile:documentfile:1.0.1")
}

flutter {
    source = "../.."
}
