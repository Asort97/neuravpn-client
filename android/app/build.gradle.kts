import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val envStoreFile = System.getenv("ANDROID_KEYSTORE_PATH")
val envKeyAlias = System.getenv("ANDROID_KEY_ALIAS")
val envKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")
val envStorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
val hasEnvReleaseKeystore =
    !envStoreFile.isNullOrBlank() &&
    !envKeyAlias.isNullOrBlank() &&
    !envKeyPassword.isNullOrBlank() &&
    !envStorePassword.isNullOrBlank()
val hasReleaseSigning = hasReleaseKeystore || hasEnvReleaseKeystore
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

if (releaseRequested && !hasReleaseSigning) {
    throw GradleException(
        "Release signing is required. Configure android/key.properties or ANDROID_KEYSTORE_* variables."
    )
}

if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { stream ->
        keystoreProperties.load(stream)
    }
}

android {
    namespace = "com.neuravpn.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.neuravpn.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                if (hasReleaseKeystore) {
                    keyAlias = keystoreProperties["keyAlias"] as String
                    keyPassword = keystoreProperties["keyPassword"] as String
                    storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                    storePassword = keystoreProperties["storePassword"] as String
                } else {
                    keyAlias = envKeyAlias!!
                    keyPassword = envKeyPassword!!
                    storeFile = rootProject.file(envStoreFile!!)
                    storePassword = envStorePassword!!
                }
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files("libs/libXray.aar"))
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("com.google.android.play:app-update-ktx:2.1.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16")
}

// Flutter has one cross-platform asset manifest. Remove desktop-only payloads
// from every Android variant after Flutter copies its assets. Android code
// never resolves these entries; Windows builds continue to use the source files.
tasks.matching { it.name.startsWith("copyFlutterAssets") }.configureEach {
    val variant = name.removePrefix("copyFlutterAssets")
    val variantDirectory = variant.replaceFirstChar { it.lowercase() }
    doLast {
        val flutterAssets = layout.buildDirectory
            .dir("intermediates/assets/$variantDirectory/merge${variant}Assets/flutter_assets")
            .get()
            .asFile
        listOf(
            "assets/bin",
            "assets/zapret",
            "assets/images/anim_connect",
            "assets/images/anim_disconnect",
            "windows",
        ).forEach { relativePath ->
            project.delete(flutterAssets.resolve(relativePath))
        }
    }
}
