plugins {
    id("com.android.application")
    id("com.google.dagger.hilt.android")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("com.diffplug.spotless") version "6.23.2"
    id("com.google.firebase.appdistribution")
    id("kotlin-parcelize")
    id("androidx.navigation.safeargs")

    kotlin("android")
    kotlin("kapt")
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
        target("**/*.kt")
        targetExclude("**/generated/*")
        licenseHeader("/* Licensed under Apache 2.0 (C) \$YEAR Firezone, Inc. */", "^(package |import |@file)")
    }
    kotlinGradle {
        ktlint()
        target("**/*.gradle.kts")
        targetExclude("**/generated/*")
    }
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

    signingConfigs {
        create("release") {
            // Find this in the Engineering 1Password vault
            storeFile = file(System.getenv("KEYSTORE_PATH") ?: "keystore.jks")
            keyAlias = "upload"
            storePassword = System.getenv("KEYSTORE_PASSWORD") ?: ""
            keyPassword = System.getenv("KEYSTORE_KEY_PASSWORD") ?: ""
        }
    }

    buildTypes {
        // Debug Config
        getByName("debug") {
            isDebuggable = true
            resValue("string", "app_name", "\"Firezone (Dev)\"")

            buildConfigField("String", "AUTH_BASE_URL", "\"https://app.firez.one\"")
            buildConfigField("String", "API_URL", "\"wss://api.firez.one\"")
            buildConfigField(
                "String",
                "LOG_FILTER",
                "\"connlib_client_android=debug,firezone_tunnel=trace,connlib_shared=debug,connlib_client_shared=debug,warn\"",
            )
        }

        // Release Config
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")

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
                "proguard-rules.pro",
            )
            isDebuggable = false

            resValue("string", "app_name", "\"Firezone\"")

            buildConfigField("String", "AUTH_BASE_URL", "\"https://app.firezone.dev\"")
            buildConfigField("String", "API_URL", "\"wss://api.firezone.dev\"")
            buildConfigField(
                "String",
                "LOG_FILTER",
                "\"connlib_client_android=info,firezone_tunnel=trace,connlib_shared=info,connlib_client_shared=info,warn\"",
            )
            firebaseAppDistribution {
                serviceCredentialsFile = System.getenv("FIREBASE_CREDENTIALS_PATH")
                artifactType = "AAB"
                releaseNotes = "https://github.com/firezone/firezone/releases"
                groups = "firezone-engineering, firezone-go-to-market"
                artifactPath = "app/build/outputs/bundle/release/app-release.aab"
            }
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
    val coreVersion = "1.12.0"
    val navVersion = "2.7.4"

    // Connlib
    implementation(project(":connlib"))

    // AndroidX
    implementation("androidx.core:core-ktx:$coreVersion")
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
    implementation("androidx.navigation:navigation-fragment-ktx:$navVersion")
    implementation("androidx.navigation:navigation-ui-ktx:$navVersion")

    // Safe Args
    //

    // Hilt
    implementation("com.google.dagger:hilt-android:2.48.1")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.core:core-ktx:$coreVersion")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.6.1")
    kapt("androidx.hilt:hilt-compiler:1.0.0")
    kapt("com.google.dagger:hilt-android-compiler:2.48.1")

    // Retrofit 2
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-moshi:2.9.0")

    // OkHttp
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // Moshi
    implementation("com.squareup.moshi:moshi-kotlin:1.15.0")
    implementation("com.squareup.moshi:moshi:1.15.0")

    // Gson
    implementation("com.google.code.gson:gson:2.10.1")

    // Security
    implementation("androidx.security:security-crypto:1.1.0-alpha05")

    // JUnit
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    implementation("androidx.browser:browser:1.5.0")

    // Import the BoM for the Firebase platform
    implementation(platform("com.google.firebase:firebase-bom:32.3.1"))

    // Add the dependencies for the Crashlytics and Analytics libraries
    // When using the BoM, you don't specify versions in Firebase library dependencies
    implementation("com.google.firebase:firebase-crashlytics-ktx")
    implementation("com.google.firebase:firebase-analytics-ktx")
    implementation("com.google.firebase:firebase-installations-ktx")
}
