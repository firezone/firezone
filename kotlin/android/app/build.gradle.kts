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
    namespace = "dev.firezone.android"

    compileSdk = 33
    defaultConfig {
        applicationId = "dev.firezone.android"
        minSdk = 29
        targetSdk = 33
        versionCode = 1
        versionName = "1.0"
        multiDexEnabled = true
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        // Debug Config
        getByName("debug") {
            isDebuggable = true

            val localProperties = Properties()
            localProperties.load(FileInputStream(rootProject.file("local.properties")))
            buildConfigField("String", "TOKEN", "\"${localProperties.getProperty("token")}\"")
            manifestPlaceholders["appLinkHostName"] = "10.0.2.2"
            manifestPlaceholders["appLinkScheme"] = "http"
            manifestPlaceholders["appLinkPort"] = "13000"
            buildConfigField("String", "AUTH_HOST", "\"10.0.2.2\"")
            buildConfigField("String", "AUTH_SCHEME", "\"http\"")
            buildConfigField("Integer", "AUTH_PORT", "13000")
            buildConfigField("String", "CONTROL_PLANE_URL", "\"ws://10.0.2.2:13001/\"")

            // Docs on filter strings: https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html
            buildConfigField("String", "CONNLIB_LOG_FILTER_STRING", "\"connlib_android=debug,firezone_tunnel=trace,libs_common=debug,firezone_client_connlib=debug,warn\"")

            resValue("string", "app_name", "\"Firezone (Dev)\"")
        }

        // Release Config
        getByName("release") {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            buildConfigField("String", "TOKEN", "null")
            manifestPlaceholders["appLinkHostName"] = "app.firez.one"
            manifestPlaceholders["appLinkScheme"] = "https"
            manifestPlaceholders["appLinkPort"] = "443"
            buildConfigField("String", "AUTH_HOST", "\"app.firezone.dev\"")
            buildConfigField("String", "AUTH_SCHEME", "\"https\"")
            buildConfigField("Integer", "AUTH_PORT", "443")
            buildConfigField("String", "CONTROL_PLANE_URL", "\"wss://api.firezone.dev/\"")

            // Docs on filter strings: https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html
            buildConfigField("String", "CONNLIB_LOG_FILTER_STRING", "\"connlib_android=info,firezone_tunnel=info,libs_common=info,firezone_client_connlib=info,warn\"")

            resValue("string", "app_name", "\"Firezone\"")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    buildFeatures {
        viewBinding = true
    }
}

dependencies {
    val core_version = "1.9.0"

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
