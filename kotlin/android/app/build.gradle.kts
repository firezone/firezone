/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("kotlin-kapt")
    id("dagger.hilt.android.plugin")
    id("kotlin-parcelize")
    id("androidx.navigation.safeargs")
    id("com.google.android.libraries.mapsplatform.secrets-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("com.diffplug.spotless") version "6.21.0"
}

spotless {
    format("misc") {
        target("*.gradle", "*.md", ".gitignore")
        trimTrailingWhitespace()
        indentWithSpaces()
        endWithNewline()
    }
    kotlin {
        ktlint()
        target("**/*.kt", "**/*.kts")
        targetExclude("**/generated/*")
        licenseHeader("/* Licensed under Apache 2.0 (C) \$YEAR Firezone, Inc. */")
    }
    kotlinGradle {
        target("**/*.gradle.kts")
        ktlint()
    }
}

tasks.named("build").configure {
    dependsOn("spotlessApply")
}

android {
    buildFeatures {
        buildConfig = true
    }

    namespace = "dev.firezone.android"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.firezone.android"
        minSdk = 30
        targetSdk = 33
        versionCode = (System.currentTimeMillis() / 1000 / 10).toInt()
        // mark:automatic-version
        versionName = "1.20231001.0"
        multiDexEnabled = true
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        // Debug Config
        getByName("debug") {
            isDebuggable = true

            val localProperties = Properties()
            localProperties.load(FileInputStream(rootProject.file("local.properties")))
            buildConfigField("String", "AUTH_HOST", "\"app.firez.one\"")
            buildConfigField("String", "AUTH_SCHEME", "\"https\"")
            buildConfigField("Integer", "AUTH_PORT", "443")
            buildConfigField("String", "CONTROL_PLANE_URL", "\"wss://api.firez.one/\"")

            // Docs on filter strings: https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html
            buildConfigField("String", "CONNLIB_LOG_FILTER_STRING", "\"connlib_client_android=debug,firezone_tunnel=trace,connlib_shared=debug,connlib_client_shared=debug,warn\"")

            resValue("string", "app_name", "\"Firezone (Dev)\"")
        }

        // Release Config
        getByName("release") {
            // Enables code shrinking, obfuscation, and optimization for only
            // your project's release build type. Make sure to use a build
            // variant with `isDebuggable=false`.
            isMinifyEnabled = true

            // Enables resource shrinking, which is performed by the
            // Android Gradle plugin.
            isShrinkResources = true

            // Includes the default ProGuard rules files that are packaged with
            // the Android Gradle plugin. To learn more, go to the section about
            // R8 configuration files.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            isDebuggable = false

            buildConfigField("String", "AUTH_HOST", "\"app.firezone.dev\"")
            buildConfigField("String", "AUTH_SCHEME", "\"https\"")
            buildConfigField("Integer", "AUTH_PORT", "443")
            buildConfigField("String", "CONTROL_PLANE_URL", "\"wss://api.firezone.dev/\"")

            // Docs on filter strings: https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html
            buildConfigField("String", "CONNLIB_LOG_FILTER_STRING", "\"connlib_client_android=info,firezone_tunnel=info,connlib_shared=info,connlib_client_shared=info,warn\"")

            resValue("string", "app_name", "\"Firezone\"")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
    }
}

dependencies {
    val core_version = "1.12.0"

    // Connlib
    implementation(project(":connlib"))

    // AndroidX
    implementation("androidx.core:core-ktx:$core_version")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.preference:preference-ktx:1.2.0")

    // Material
    implementation("com.google.android.material:material:1.8.0")

    // Lifecycle
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.6.1")
    implementation("androidx.lifecycle:lifecycle-extensions:2.2.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.6.1")
    implementation("androidx.lifecycle:lifecycle-livedata-ktx:2.6.1")

    // Navigation
    implementation("androidx.navigation:navigation-fragment-ktx:2.5.3")
    implementation("androidx.navigation:navigation-ui-ktx:2.5.3")

    // Hilt
    implementation("com.google.dagger:hilt-android:2.44.1")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.core:core-ktx:$core_version")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.6.1")
    kapt("androidx.hilt:hilt-compiler:1.0.0")
    kapt("com.google.dagger:hilt-android-compiler:2.44.1")

    // Retrofit 2
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-moshi:2.9.0")

    // OkHttp
    implementation("com.squareup.okhttp3:okhttp:4.10.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.9.1")

    // Moshi
    implementation("com.squareup.moshi:moshi-kotlin:1.12.0")
    implementation("com.squareup.moshi:moshi:1.12.0")

    // Gson
    implementation("com.google.code.gson:gson:2.9.0")

    // Security
    implementation("androidx.security:security-crypto:1.1.0-alpha05")

    // JUnit
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    implementation("androidx.browser:browser:1.5.0")

    // Import the BoM for the Firebase platform
    implementation(platform("com.google.firebase:firebase-bom:32.2.2"))

    // Add the dependencies for the Crashlytics and Analytics libraries
    // When using the BoM, you don't specify versions in Firebase library dependencies
    implementation("com.google.firebase:firebase-crashlytics-ktx")
    implementation("com.google.firebase:firebase-analytics-ktx")
    implementation("com.google.firebase:firebase-installations-ktx")
}
