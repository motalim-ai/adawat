plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.motalim.adawat"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.motalim.adawat"
        minSdk = 29
        targetSdk = 37
        versionName = "1.1.0"
        // 1.2.3 → 10203, so every release installs over the one before it.
        versionCode = versionName!!.split(".").fold(0) { code, part -> code * 100 + part.toInt() }
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    // The upload key stays outside the repository: its path and passwords come from ~/.gradle/gradle.properties
    // (adawat.storeFile, adawat.storePassword, adawat.keyAlias, adawat.keyPassword). Without them, release builds are unsigned.
    val upload = providers.gradleProperty("adawat.storeFile").orNull
    signingConfigs {
        if (upload != null) create("upload") {
            storeFile = file(upload)
            storePassword = providers.gradleProperty("adawat.storePassword").get()
            keyAlias = providers.gradleProperty("adawat.keyAlias").get()
            keyPassword = providers.gradleProperty("adawat.keyPassword").get()
        }
    }

    buildTypes {
        release {
            if (upload != null) signingConfig = signingConfigs.getByName("upload")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    androidResources {
        // The OCR models are read from a copy on disk, so keep them whole.
        noCompress += "traineddata"
    }

    ndkVersion = "29.0.14206865"
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "4.1.2"
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // The Arabic strings are shared with the Windows and Linux apps.
    sourceSets["main"].assets.directories += "../../windows/shared"
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.androidx.exifinterface)
    implementation(libs.androidx.heifwriter)
    implementation(libs.androidx.print)
    implementation(libs.androidx.documentfile)
    implementation(libs.zxing.core)
    implementation(libs.tesseract)
    implementation(libs.pdfbox)
    implementation(libs.media3.transformer)
    implementation(libs.media3.effect)
    implementation(libs.media3.common)
    implementation(libs.media3.muxer)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.ui)
    implementation(libs.jsoup)
    implementation(libs.commonmark)
    implementation(libs.commonmark.tables)
    implementation(libs.kotlinx.coroutines.android)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
}
