import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties, which is gitignored and
// looks like this (see android/key.properties.example):
//
//   storeFile=upload-keystore.jks     # relative to android/app/
//   storePassword=...
//   keyAlias=upload
//   keyPassword=...
//
// The passwords used to be hardcoded here, in a public-ish repo, next to the
// name of a keystore that was never committed. Now: when the file is present
// the release build is signed with the upload key; when it is absent the
// release build falls back to the debug key with a loud warning, so
// `flutter build apk --release` still produces something installable for
// testing, and only a real Play upload is blocked (Play rejects debug-signed
// bundles, which is the failure we want).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
} else {
    logger.warn(
        "WARNING: android/key.properties not found - release builds will be " +
            "signed with the DEBUG key. Fine for a device test, not for Play."
    )
}

android {
    namespace = "com.aiboyfriend.mymate"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications needs java.time on API < 26 and desugared
        // collections everywhere; keep this on even though minSdk is 26.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // The Google Play identity, and it cannot change: the listing the
        // previous owner published ("MyMate: AI Boyfriend Chat", 164 installs,
        // last release versionCode 22) lives under this package, and an update
        // only reaches those users if the bundle carries the same name. It
        // differs from the Kotlin namespace above on purpose - the namespace
        // is only where R and MainActivity resolve - and from the iOS bundle
        // id, which is fine; the stores never compare them.
        applicationId = "com.iosappv2.ai_boyfriend_chat"
        // 26 is what flutter_local_notifications' desugaring was set up for,
        // and covers effectively every active device. Flutter picks the
        // compile/target SDK so Play's yearly target-API requirement is met by
        // upgrading Flutter, not by editing this file.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Both come from pubspec.yaml `version: x.y.z+N` - N is versionCode.
        // Play needs every upload's versionCode to be higher than the last, so
        // bump the +N in pubspec.yaml before each release, same as for iOS.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
