// Developer: Mersad Karimi <mersadkarimi001@gmail.com>

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.internet_management"
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
        applicationId = "com.example.internet_management"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // حداقل SDK 19 برای flutter_inappwebview
        minSdk = maxOf(flutter.minSdkVersion, 21)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Keep the same debug keystore used by previous APKs on this machine
            // so sideload updates are not rejected as invalid/signature mismatch.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // تنظیم نام خودکار فایل APK/AAB
    // Developer: Mersad Karimi <mersadkarimi001@gmail.com>
    // فرمت خروجی: Ariyabod-v1.0.0(1)-release.apk
    // این کد به صورت خودکار نام فایل APK را بر اساس نام برنامه، نسخه و نوع build تنظیم می‌کند
    applicationVariants.all {
        val variant = this
        val appName = "Ariyabod"
        val versionName = variant.versionName
        val versionCode = variant.versionCode
        val buildType = variant.buildType.name
        
        variant.outputs.all {
            val outputFileName = "${appName}-v${versionName}(${versionCode})-${buildType}.apk"
            (this as com.android.build.gradle.internal.api.BaseVariantOutputImpl).outputFileName = outputFileName
        }
    }
}

flutter {
    source = "../.."
}
