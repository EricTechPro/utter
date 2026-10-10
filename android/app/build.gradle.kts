plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "local.utter"
    compileSdk = 35

    defaultConfig {
        applicationId = "local.utter"
        minSdk = 26
        targetSdk = 35
        versionCode = 3
        versionName = "0.3"
        ndk { abiFilters += "arm64-v8a" }
    }

    ndkVersion = "27.2.12479018"
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.31.5"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Signed with the debug key so it can be sideloaded straight from Google Drive.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
