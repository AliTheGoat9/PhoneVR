plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.phonevr"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.phonevr"
        minSdk = 31          // Surface.setFrameRate(..., changeFrameRateStrategy) needs 31
        targetSdk = 35       // see README: newer targets may require a local-network permission
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")   // so assembleRelease is installable without a keystore
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
