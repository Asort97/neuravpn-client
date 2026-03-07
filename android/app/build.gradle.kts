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

if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { stream ->
        keystoreProperties.load(stream)
    }
}

android {
    namespace = "com.neuravpn.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
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
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files("libs/libbox.aar"))
    implementation("androidx.activity:activity-ktx:1.9.3")
}
