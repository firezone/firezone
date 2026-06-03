import com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension
import groovy.json.JsonSlurper
import java.io.ByteArrayOutputStream

plugins {
    id("org.mozilla.rust-android-gradle.rust-android")
    id("com.android.application")
    id("com.google.dagger.hilt.android")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("com.diffplug.spotless") version "8.5.1"
    id("kotlin-parcelize")
    id("androidx.navigation.safeargs")

    kotlin("android")
    kotlin("kapt")
    id("org.jetbrains.kotlin.plugin.compose")
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
        versionName = "1.5.11"
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
        compose = true
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }

    // Escalate Slack's Compose lint checks (added via `lintChecks`) to build-failing
    // errors so Compose issues block CI. Other checks keep their default severity.
    // `ComposeM2Api` is intentionally omitted: it is opt-in in the library and this
    // app is on Material 3.
    lint {
        error +=
            setOf(
                "ComposeCompositionLocalGetter",
                "ComposeCompositionLocalUsage",
                "ComposeContentEmitterReturningValues",
                "ComposeModifierComposed",
                "ComposeModifierMissing",
                "ComposeModifierReused",
                "ComposeModifierWithoutDefault",
                "ComposeMultipleContentEmitters",
                "ComposeMutableParameters",
                "ComposeNamingLowercase",
                "ComposeNamingUppercase",
                "ComposeParameterOrder",
                "ComposePreviewNaming",
                "ComposePreviewPublic",
                "ComposeRememberMissing",
                "ComposeUnstableCollections",
                "ComposeUnstableReceiver",
                "ComposeViewModelForwarding",
                "ComposeViewModelInjection",
                "SlotReused",
            )
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.2.0")
    // Desugaring - needed for Java 8+ APIs on older Android versions
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // AndroidX
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.preference:preference-ktx:1.2.1")
    implementation("androidx.constraintlayout:constraintlayout:2.2.1")

    // Material
    implementation("com.google.android.material:material:1.14.0")

    // Lifecycle
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("androidx.lifecycle:lifecycle-extensions:2.2.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.10.0")
    implementation("androidx.lifecycle:lifecycle-livedata-ktx:2.10.0")

    // Navigation
    implementation("androidx.navigation:navigation-fragment-ktx:2.9.7")
    implementation("androidx.navigation:navigation-ui-ktx:2.9.7")

    // Hilt
    implementation("com.google.dagger:hilt-android:2.58")
    implementation("androidx.browser:browser:1.10.0")
    implementation("com.google.firebase:firebase-installations")
    implementation("com.google.android.gms:play-services-tasks:18.4.1")
    kapt("androidx.hilt:hilt-compiler:1.3.0")
    kapt("com.google.dagger:hilt-android-compiler:2.58")
    // Instrumented Tests
    androidTestImplementation("com.google.dagger:hilt-android-testing:2.58")
    kaptAndroidTest("com.google.dagger:hilt-android-compiler:2.58")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.navigation:navigation-testing:2.9.7")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-contrib:3.7.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
    // Unit Tests
    testImplementation("com.google.dagger:hilt-android-testing:2.58")

    // Retrofit 2
    implementation("com.squareup.retrofit2:retrofit:3.0.0")
    implementation("com.squareup.retrofit2:converter-moshi:3.0.0")

    // OkHttp
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    implementation("com.squareup.okhttp3:logging-interceptor:5.3.2")

    // Moshi
    implementation("com.squareup.moshi:moshi-kotlin:1.15.2")
    implementation("com.squareup.moshi:moshi:1.15.2")

    // Gson
    implementation("com.google.code.gson:gson:2.14.0")

    // Security
    implementation("androidx.security:security-crypto:1.1.0")

    // JUnit
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.fragment:fragment-testing:1.8.9")

    // Import the BoM for the Firebase platform
    implementation(platform("com.google.firebase:firebase-bom:34.13.0"))

    // Add the dependencies for the Crashlytics and Analytics libraries
    // When using the BoM, you don't specify versions in Firebase library dependencies
    implementation("com.google.firebase:firebase-crashlytics")
    implementation("com.google.firebase:firebase-crashlytics-ndk")
    implementation("com.google.firebase:firebase-analytics")

    // UniFFI
    implementation("net.java.dev.jna:jna:5.18.1@aar")

    // Sentry
    implementation("io.sentry:sentry-android:8.42.0")

    // Compose
    val composeBom = platform("androidx.compose:compose-bom:2025.05.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    // Immutable collections give Compose stable (skippable) parameter types.
    implementation("org.jetbrains.kotlinx:kotlinx-collections-immutable:0.4.0")

    // Slack's Compose lint checks. Pinned to 1.4.2: lint check JARs are versioned to
    // the lint API (`lint = AGP + 23`), so with AGP 8.13 (lint 31.13) we need a build
    // against an older lint. 1.4.3+/1.5.0 target lint 32.2 (AGP 9.2) and get rejected.
    lintChecks("com.slack.lint.compose:compose-lint-checks:1.4.2")
}

val rustDir = layout.projectDirectory.dir("../../../rust")

// Resolve the cargo target directory from cargo metadata so we don't hardcode a path that may
// be overridden by the user's ~/.cargo/config.toml (e.g. `target-dir`).
val cargoTargetDir: String by lazy {
    val metadataOutput = ByteArrayOutputStream()
    project.exec {
        workingDir = rustDir.asFile
        commandLine("cargo", "metadata", "--format-version", "1")
        standardOutput = metadataOutput
    }
    val metadataJson = metadataOutput.toString(Charsets.UTF_8.name())
    val metadata =
        try {
            JsonSlurper().parseText(metadataJson) as Map<*, *>
        } catch (e: Exception) {
            throw GradleException(
                "Failed to parse cargo metadata JSON. Ensure 'cargo' is installed and accessible. Error: ${e.message}",
                e,
            )
        }
    metadata["target_directory"] as? String
        ?: throw GradleException(
            "cargo metadata did not contain 'target_directory' field. Output was: ${metadataJson.take(500)}",
        )
}

// Resolve the target Android ABI from the `android.injected.build.abi` Gradle property,
// injected by Android Studio when launching on a connected device (comma-separated, preferred
// ABI first) and passed explicitly by `mise-tasks/install-phone.sh`. When unset (e.g. plain
// `assembleDebug` or CI), build all ABIs.
val targetAndroidAbi: String? =
    providers
        .gradleProperty("android.injected.build.abi")
        .orNull
        ?.split(",")
        ?.firstOrNull()
        ?.trim()
        ?.takeIf { it.isNotEmpty() }

fun androidAbiToCargoTarget(abi: String): String =
    when (abi) {
        "arm64-v8a" -> "arm64"
        "armeabi-v7a" -> "arm"
        "x86" -> "x86"
        "x86_64" -> "x86_64"
        else -> throw GradleException("Unsupported ABI '$abi'. Supported: arm64-v8a, armeabi-v7a, x86, x86_64.")
    }

fun androidAbiToRustTriple(abi: String): String =
    when (abi) {
        "arm64-v8a" -> "aarch64-linux-android"
        "armeabi-v7a" -> "armv7-linux-androideabi"
        "x86" -> "i686-linux-android"
        "x86_64" -> "x86_64-linux-android"
        else -> throw GradleException("Unsupported ABI '$abi'. Supported: arm64-v8a, armeabi-v7a, x86, x86_64.")
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
        targetAndroidAbi?.let { listOf(androidAbiToCargoTarget(it)) }
            ?: listOf("arm64", "x86_64", "x86", "arm")
    targetDirectory = cargoTargetDir
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

        val outDir = layout.buildDirectory.dir("generated/source/uniffi/$profile").get()

        // UniFFI bindings are identical across ABIs, so we only need one libconnlib.so as input.
        // Point this task at an ABI that actually gets built when callers narrow the target list
        // via `android.injected.build.abi`. Defaults to x86_64 so the all-ABI build keeps working.
        val rustTargetTriple =
            targetAndroidAbi?.let { androidAbiToRustTriple(it) } ?: "x86_64-linux-android"
        val inputFile = file("$cargoTargetDir/$rustTargetTriple/$profile/libconnlib.so")

        inputs.file(inputFile)
        outputs.dir(outDir)

        doLast {
            // Execute uniffi-bindgen command from the rust directory
            project.exec {
                // Spawn a shell to run the command; fixes PATH race conditions that can cause
                // the cargo executable to not be found even though it is in the PATH.
                commandLine(
                    "sh",
                    "-c",
                    "cd ${rustDir.asFile} && cargo run --bin uniffi-bindgen generate --library --language kotlin $inputFile --out-dir ${outDir.asFile}",
                )
            }
        }
    }

tasks.matching { it.name.matches(Regex("merge.*JniLibFolders")) }.configureEach {
    inputs.dir(layout.buildDirectory.file("rustJniLibs/android"))
    dependsOn("cargoBuild")
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
