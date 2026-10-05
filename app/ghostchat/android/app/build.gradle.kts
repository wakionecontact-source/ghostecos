import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // Firebase (FCM): применяем google-services (читает google-services.json).
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release builds must use a real private key. Never fall back to the Android
// debug key: that makes APKs look like development artifacts and can trigger
// antivirus heuristics. The actual file is ignored by git.
val releaseKeyPropertiesFile = rootProject.file("key.properties")
val releaseKeyProperties = Properties()
if (releaseKeyPropertiesFile.isFile) {
    FileInputStream(releaseKeyPropertiesFile).use { releaseKeyProperties.load(it) }
}
val releaseSigningReady = releaseKeyPropertiesFile.isFile && listOf(
    "keyAlias",
    "keyPassword",
    "storeFile",
    "storePassword",
).all { releaseKeyProperties.getProperty(it)?.isNotBlank() == true }

android {
    namespace = "online.ghost_chat.ghost"
    compileSdk = 36                          // требуется flutter_plugin_android_lifecycle
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Нужно для flutter_local_notifications + других плагинов
        // которые используют API java.time.* на minSdk ниже 26.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "online.ghost_chat.chat"
        minSdk = flutter.minSdkVersion                        // Android 6.0+ — для записи аудио и secure_storage
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            if (releaseSigningReady) {
                keyAlias = releaseKeyProperties.getProperty("keyAlias")
                keyPassword = releaseKeyProperties.getProperty("keyPassword")
                storeFile = file(releaseKeyProperties.getProperty("storeFile"))
                storePassword = releaseKeyProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// Make the failure explicit for every release task while leaving debug builds
// and local development unaffected.
if (!releaseSigningReady) {
    tasks.configureEach {
        if (name.contains("Release", ignoreCase = true)) {
            doFirst {
                throw GradleException(
                    "Release signing is not configured. Fill android/key.properties " +
                        "from android/key.properties.example with the project release keystore."
                )
            }
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
