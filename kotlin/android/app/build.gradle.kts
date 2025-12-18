import com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension

plugins {
    id("org.mozilla.rust-android-gradle.rust-android")
    id("com.android.application")
    id("com.google.dagger.hilt.android")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("com.diffplug.spotless") version "8.1.0"
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
        leadingTabsToSpaces()
        endWithNewline()
    }
    kotlin {
        ktlint()
        target("**/*.kt")
        targetExclude("**/generated/*")
        licenseHeader("// Licensed under Apache 2.0 (C) \$YEAR Firezone, Inc.", "^(package |import |@file)")
    }
    kotlinGradle {
        ktlint()
        target("**/*.gradle.kts")
        targetExclude("**/generated/*")
    }
}

apply(plugin = "org.mozilla.rust-android-gradle.rust-android")

android {
    buildFeatures {
        buildConfig = true
    }

    namespace = "dev.firezone.android"
    compileSdk = 36
    ndkVersion = "28.1.13356709" // Must match `.github/actions/setup-android/action.yml`

    defaultConfig {
        applicationId = "dev.firezone.android"
        // Android 8
        minSdk = 26
        targetSdk = 36
        versionCode = (System.currentTimeMillis() / 1000 / 10).toInt()
        // mark:next-android-version
        versionName = "1.5.8"
        multiDexEnabled = true
        testInstrumentationRunner = "dev.firezone.android.core.HiltTestRunner"

        val gitSha = System.getenv("GITHUB_SHA") ?: "unknown"
        resValue("string", "git_sha", "Build: \"${gitSha.take(8)}\"")
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

            buildConfigField("String", "AUTH_URL", "\"https://app.firez.one\"")
            buildConfigField("String", "API_URL", "\"wss://api.firez.one\"")
            buildConfigField(
                "String",
                "LOG_FILTER",
                "\"debug\"",
            )
        }

        // Release Config
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")

            // Enables code shrinking, obfuscation, and optimization for only
            // your project's release build type. Make sure to use a build
            // variant with `isDebuggable=false`.
            // Not compatible with Rust
            isMinifyEnabled = false

            // Enables resource shrinking, which is performed by the
            // Android Gradle plugin.
            isShrinkResources = false

            // Includes the default ProGuard rules files that are packaged with
            // the Android Gradle plugin. To learn more, go to the section about
            // R8 configuration files.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            isDebuggable = false

            configure<CrashlyticsExtension> {
                // Enable processing and uploading of native symbols to Firebase servers.
                // By default, this is disabled to improve build speeds.
                // This flag must be enabled to see properly-symbolicated native
                // stack traces in the Crashlytics dashboard.
                nativeSymbolUploadEnabled = true
                unstrippedNativeLibsDir = layout.buildDirectory.dir("rustJniLibs")
            }

            resValue("string", "app_name", "\"Firezone\"")

            buildConfigField("String", "AUTH_URL", "\"https://app.firezone.dev\"")
            buildConfigField("String", "API_URL", "\"wss://api.firezone.dev\"")
            buildConfigField("String", "LOG_FILTER", "\"info\"")
            firebaseAppDistribution {
                serviceCredentialsFile = System.getenv("FIREBASE_CREDENTIALS_PATH")
                artifactType = "AAB"
                releaseNotes = "https://www.firezone.dev/changelog"
                groups = "firezone-engineering"
                artifactPath = "app/build/outputs/bundle/release/app-release.aab"
            }
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }
}

dependencies {
    // Desugaring - needed for Java 8+ APIs on older Android versions
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // AndroidX
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.preference:preference-ktx:1.2.1")
    implementation("androidx.constraintlayout:constraintlayout:2.2.1")

    // Material
    implementation("com.google.android.material:material:1.13.0")

    // Lifecycle
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("androidx.lifecycle:lifecycle-extensions:2.2.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.10.0")
    implementation("androidx.lifecycle:lifecycle-livedata-ktx:2.10.0")

    // Navigation
    implementation("androidx.navigation:navigation-fragment-ktx:2.9.6")
    implementation("androidx.navigation:navigation-ui-ktx:2.9.6")

    // Hilt
    implementation("com.google.dagger:hilt-android:2.57.2")
    implementation("androidx.browser:browser:1.9.0")
    implementation("com.google.firebase:firebase-installations")
    implementation("com.google.android.gms:play-services-tasks:18.4.0")
    kapt("androidx.hilt:hilt-compiler:1.3.0")
    kapt("com.google.dagger:hilt-android-compiler:2.57.2")
    // Instrumented Tests
    androidTestImplementation("com.google.dagger:hilt-android-testing:2.57.2")
    kaptAndroidTest("com.google.dagger:hilt-android-compiler:2.57.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.navigation:navigation-testing:2.9.6")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-contrib:3.7.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
    // Unit Tests
    testImplementation("com.google.dagger:hilt-android-testing:2.57.2")

    // Retrofit 2
    implementation("com.squareup.retrofit2:retrofit:3.0.0")
    implementation("com.squareup.retrofit2:converter-moshi:3.0.0")

    // OkHttp
    implementation("com.squareup.okhttp3:okhttp:5.3.1")
    implementation("com.squareup.okhttp3:logging-interceptor:5.3.1")

    // Moshi
    implementation("com.squareup.moshi:moshi-kotlin:1.15.2")
    implementation("com.squareup.moshi:moshi:1.15.2")

    // Gson
    implementation("com.google.code.gson:gson:2.13.2")

    // Security
    implementation("androidx.security:security-crypto:1.1.0")

    // JUnit
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.fragment:fragment-testing:1.8.9")

    // Import the BoM for the Firebase platform
    implementation(platform("com.google.firebase:firebase-bom:34.7.0"))

    // Add the dependencies for the Crashlytics and Analytics libraries
    // When using the BoM, you don't specify versions in Firebase library dependencies
    implementation("com.google.firebase:firebase-crashlytics")
    implementation("com.google.firebase:firebase-crashlytics-ndk")
    implementation("com.google.firebase:firebase-analytics")

    // UniFFI
    implementation("net.java.dev.jna:jna:5.18.1@aar")
}

cargo {
    if (gradle.startParameter.taskNames.any { it.lowercase().contains("release") }) {
        profile = "release"
    } else {
        profile = "debug"
    }
    // Needed for Ubuntu 22.04
    pythonCommand = "python3"
    prebuiltToolchains = true
    module = "../../../rust/client-ffi"
    libname = "connlib"
    targets =
        listOf(
            "arm64",
            "x86_64",
            "x86",
            "arm",
        )
    targetDirectory = "../../../rust/target"
}

// Custom task to run uniffi-bindgen
val generateUniffiBindings =
    tasks.register("generateUniffiBindings") {
        description = "Generate Kotlin bindings using uniffi-bindgen"
        group = "build"

        // This task should run after cargo build completes
        dependsOn("cargoBuild")

        // Determine the correct path to libconnlib.so based on build flavor
        val profile =
            if (gradle.startParameter.taskNames.any { it.lowercase().contains("release") }) {
                "release"
            } else {
                "debug"
            }

        val rustDir = layout.projectDirectory.dir("../../../rust")

        // Hardcode the x86_64 target here, it doesn't matter which one we use, they are
        // all the same from the bindings PoV.
        val input = rustDir.dir("target/x86_64-linux-android/$profile/libconnlib.so")
        val outDir = layout.buildDirectory.dir("generated/source/uniffi/$profile").get()

        doLast {
            // Execute uniffi-bindgen command from the rust directory
            project.exec {
                // Spawn a shell to run the command; fixes PATH race conditions that can cause
                // the cargo executable to not be found even though it is in the PATH.
                commandLine(
                    "sh",
                    "-c",
                    "cd ${rustDir.asFile} && cargo run --bin uniffi-bindgen generate --library --language kotlin ${input.asFile} --out-dir ${outDir.asFile}",
                )
            }
        }

        inputs.file(input)
        outputs.dir(outDir)
    }

tasks.matching { it.name.matches(Regex("merge.*JniLibFolders")) }.configureEach {
    inputs.dir(layout.buildDirectory.file("rustJniLibs/android"))
    dependsOn("cargoBuild")
}

tasks.matching { it.name == "appDistributionUploadRelease" }.configureEach {
    dependsOn("processReleaseGoogleServices")
}

kapt {
    correctErrorTypes = true
}

kotlin {
    sourceSets {
        main {
            kotlin.srcDir(generateUniffiBindings)
        }
    }
}
