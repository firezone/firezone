import com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension
import org.gradle.process.ExecOperations
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.io.File
import java.util.Properties
import javax.inject.Inject

plugins {
    id("com.android.application")
    id("com.google.dagger.hilt.android")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("com.diffplug.spotless") version "8.6.0"
    id("kotlin-parcelize")
    id("androidx.navigation.safeargs")
    id("com.google.devtools.ksp")

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

android {
    buildFeatures {
        buildConfig = true
        resValues = true
    }

    namespace = "dev.firezone.android"
    compileSdk = 36
    ndkVersion = "28.2.13676358" // Must be a version preinstalled on the CI runner (see setup-android)

    defaultConfig {
        applicationId = "dev.firezone.android"
        // Android 8
        minSdk = 26
        targetSdk = 36
        versionCode = (System.currentTimeMillis() / 1000 / 10).toInt()
        // mark:next-android-version
        versionName = "1.5.13"
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
            // R8 only processes JVM bytecode; classes reached from libconnlib.so
            // via JNI/JNA are preserved through proguard-rules.pro.
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
    implementation("com.google.dagger:hilt-android:2.59.2")
    implementation("androidx.browser:browser:1.10.0")
    implementation("com.google.firebase:firebase-installations")
    implementation("com.google.android.gms:play-services-tasks:18.4.1")
    ksp("androidx.hilt:hilt-compiler:1.3.0")
    ksp("com.google.dagger:hilt-android-compiler:2.59.2")
    // Instrumented Tests
    androidTestImplementation("com.google.dagger:hilt-android-testing:2.59.2")
    kspAndroidTest("com.google.dagger:hilt-android-compiler:2.59.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.navigation:navigation-testing:2.9.7")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-contrib:3.7.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
    // Unit Tests
    testImplementation("com.google.dagger:hilt-android-testing:2.59.2")

    // Retrofit 2
    implementation("com.squareup.retrofit2:retrofit:3.0.0")
    implementation("com.squareup.retrofit2:converter-moshi:3.0.0")

    // OkHttp
    implementation("com.squareup.okhttp3:okhttp:5.4.0")
    implementation("com.squareup.okhttp3:logging-interceptor:5.4.0")

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
    implementation(platform("com.google.firebase:firebase-bom:34.15.0"))

    // Add the dependencies for the Crashlytics and Analytics libraries
    // When using the BoM, you don't specify versions in Firebase library dependencies
    implementation("com.google.firebase:firebase-crashlytics")
    implementation("com.google.firebase:firebase-crashlytics-ndk")
    implementation("com.google.firebase:firebase-analytics")

    // UniFFI
    implementation("net.java.dev.jna:jna:5.19.1@aar")

    // Kotlin side of rustls-platform-verifier, called from libconnlib.so via JNI
    // (see FirezoneApp.initRustlsPlatformVerifier). Resolved from the Maven repo
    // bundled in the crate source (see settings.gradle.kts).
    implementation(cargo.rustls.platform.verifier)

    // Sentry
    implementation("io.sentry:sentry-android:8.43.2")

    // Compose
    val composeBom = platform("androidx.compose:compose-bom:2026.05.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    // Immutable collections give Compose stable (skippable) parameter types.
    implementation("org.jetbrains.kotlinx:kotlinx-collections-immutable:0.5.0")

    // Slack's Compose lint checks. Lint check JARs are versioned to the lint API
    // (`lint = AGP + 23`), so AGP 9.2 (lint 32.2) needs 1.4.3, which is built against it
    // (1.4.2 targeted lint 31.7 for AGP 8.13). We stay on 1.4.3 rather than 1.5.0: 1.5.0
    // rewrote ComposeViewModelForwarding to flag forwarding inside nested blocks, which
    // false-positives on our @Immutable ResourceViewModel (a UI model, not a real ViewModel).
    lintChecks("com.slack.lint.compose:compose-lint-checks:1.4.3")
}

val rustDir = layout.projectDirectory.dir("../../../rust")

// Cargo's target directory, not hardcoded because the user's ~/.cargo/config.toml may override
// it (e.g. `target-dir`). Resolved from the single `cargo metadata` call in settings.gradle.kts
// and shared via gradle extras.
val cargoTargetDir = (gradle as ExtensionAware).extra["cargoTargetDir"] as String

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

fun androidAbiToRustTriple(abi: String): String =
    when (abi) {
        "arm64-v8a" -> "aarch64-linux-android"
        "armeabi-v7a" -> "armv7-linux-androideabi"
        "x86" -> "i686-linux-android"
        "x86_64" -> "x86_64-linux-android"
        else -> throw GradleException("Unsupported ABI '$abi'. Supported: arm64-v8a, armeabi-v7a, x86, x86_64.")
    }

val ndkHostTag =
    System.getProperty("os.name").lowercase().let { osName ->
        when {
            osName.contains("win") -> "windows-x86_64"
            osName.contains("mac") || osName.contains("darwin") -> "darwin-x86_64"
            else -> "linux-x86_64"
        }
    }

// NDK Clang wrapper prefix for an ABI (the part before the API level). armeabi-v7a uses the
// `armv7a-linux-androideabi` Clang prefix even though its Rust triple is `armv7-linux-androideabi`.
fun androidAbiToClangPrefix(abi: String): String =
    when (abi) {
        "arm64-v8a" -> "aarch64-linux-android"
        "armeabi-v7a" -> "armv7a-linux-androideabi"
        "x86" -> "i686-linux-android"
        "x86_64" -> "x86_64-linux-android"
        else -> throw GradleException("Unsupported ABI '$abi'. Supported: arm64-v8a, armeabi-v7a, x86, x86_64.")
    }

// Resolve the installed NDK directory. AGP 9's new DSL no longer exposes `android.ndkDirectory`,
// so we locate it ourselves from the SDK or local.properties. Deliberately ignores
// ANDROID_NDK_HOME / ANDROID_NDK_ROOT: CI runners preset those to the image's default
// NDK, which silently overrode the pinned `ndkVersion`.
fun resolveNdkDir(ndkVersion: String): File {
    val sdkDir =
        System.getenv("ANDROID_HOME")
            ?: System.getenv("ANDROID_SDK_ROOT")
            ?: rootProject.file("local.properties").takeIf { it.exists() }?.let { propsFile ->
                Properties()
                    .apply { propsFile.inputStream().use { load(it) } }
                    .getProperty("sdk.dir")
            }
            ?: throw GradleException(
                "Cannot locate the Android SDK. Set ANDROID_HOME or `sdk.dir` in local.properties.",
            )
    val ndkDir = file(sdkDir).resolve("ndk").resolve(ndkVersion)
    if (!ndkDir.isDirectory) {
        throw GradleException(
            "Android NDK $ndkVersion not found at $ndkDir. Install it with `mise run setup-ndk`.",
        )
    }
    return ndkDir
}

// Cross-compile connlib (Rust) for the selected Android ABIs and stage each library under
// `build/rustJniLibs/android/<abi>/` for AGP to package. Replaces the rust-android-gradle plugin,
// which is incompatible with the AGP 9 / Gradle 9 toolchain. We point cargo at the NDK Clang
// wrappers per target; connlib's only C dependency is ring, which just needs CC/AR.
abstract class CargoBuildTask
    @Inject
    constructor() : DefaultTask() {
        // Maps each Android ABI (jniLibs dir name) to its Rust target triple.
        @get:Input
        abstract val abiTriples: MapProperty<String, String>

        // Maps each Android ABI to its NDK Clang wrapper prefix.
        @get:Input
        abstract val abiClangPrefixes: MapProperty<String, String>

        @get:Input
        abstract val release: Property<Boolean>

        @get:Input
        abstract val apiLevel: Property<Int>

        @get:Input
        abstract val toolchainBinDir: Property<String>

        @get:Input
        abstract val clangSuffix: Property<String>

        @get:Input
        abstract val cargoTargetDirectory: Property<String>

        @get:Internal
        abstract val clientFfiDir: DirectoryProperty

        @get:OutputDirectory
        abstract val jniLibsDir: DirectoryProperty

        @get:Inject
        abstract val execOperations: ExecOperations

        @TaskAction
        fun build() {
            val triples = abiTriples.get()
            val clangPrefixes = abiClangPrefixes.get()
            val cargoTarget = cargoTargetDirectory.get()
            val profileDir = if (release.get()) "release" else "debug"
            val binDir = File(toolchainBinDir.get())
            val suffix = clangSuffix.get()
            val api = apiLevel.get()
            val archiver = File(binDir, "llvm-ar")

            for ((abi, triple) in triples) {
                val clangPrefix = clangPrefixes.getValue(abi)
                val clang = File(binDir, "$clangPrefix$api-clang$suffix")
                val clangxx = File(binDir, "$clangPrefix$api-clang++$suffix")
                val envTriple = triple.uppercase().replace('-', '_')

                execOperations.exec {
                    workingDir = clientFfiDir.get().asFile
                    environment("CARGO_TARGET_DIR", cargoTarget)
                    if (release.get()) {
                        // Compile the whole dependency graph with line tables so
                        // Crashlytics gets file/line info in native stack traces.
                        // AGP strips them from the packaged lib; Crashlytics uploads
                        // the unstripped one (see unstrippedNativeLibsDir).
                        environment("CARGO_PROFILE_RELEASE_DEBUG", "line-tables-only")
                    }
                    // Linker for the Rust target plus the C/C++ toolchain for `cc`-built
                    // dependencies such as ring.
                    environment("CARGO_TARGET_${envTriple}_LINKER", clang.absolutePath)
                    // Google Play requires 16 KB page-size support. NDK r28+ aligns ELF
                    // LOAD segments to 16 KB by default but older NDKs use 4 KB, so pass
                    // the flag explicitly rather than relying on the toolchain default.
                    environment(
                        "CARGO_TARGET_${envTriple}_RUSTFLAGS",
                        "-C link-arg=-Wl,-z,max-page-size=16384",
                    )
                    environment("CC_$triple", clang.absolutePath)
                    environment("CXX_$triple", clangxx.absolutePath)
                    environment("AR_$triple", archiver.absolutePath)
                    val cargoArgs = mutableListOf("cargo", "build", "--lib", "--target", triple)
                    if (release.get()) {
                        cargoArgs.add("--release")
                    }
                    commandLine(cargoArgs)
                }
            }

            // Stage libconnlib.so per ABI.
            val outDir = jniLibsDir.get().asFile
            outDir.deleteRecursively()
            for ((abi, triple) in triples) {
                val abiDir = File(outDir, abi).apply { mkdirs() }
                File("$cargoTarget/$triple/$profileDir/libconnlib.so")
                    .copyTo(File(abiDir, "libconnlib.so"), overwrite = true)
            }
        }
    }

val cargoBuild =
    tasks.register<CargoBuildTask>("cargoBuild") {
        description = "Cross-compile connlib (Rust) for the selected Android ABIs"
        group = "build"

        val ndkVersion =
            android.ndkVersion ?: throw GradleException("android.ndkVersion is not set.")
        val selectedAbis =
            targetAndroidAbi?.let { listOf(it) }
                ?: listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")

        val minSdk =
            android.defaultConfig.minSdk ?: throw GradleException("android.defaultConfig.minSdk is not set.")

        release.set(gradle.startParameter.taskNames.any { it.lowercase().contains("release") })
        apiLevel.set(minSdk)
        abiTriples.set(selectedAbis.associateWith { androidAbiToRustTriple(it) })
        abiClangPrefixes.set(selectedAbis.associateWith { androidAbiToClangPrefix(it) })
        toolchainBinDir.set(
            resolveNdkDir(ndkVersion).resolve("toolchains/llvm/prebuilt/$ndkHostTag/bin").absolutePath,
        )
        clangSuffix.set(if (ndkHostTag.startsWith("windows")) ".cmd" else "")
        cargoTargetDirectory.set(cargoTargetDir)
        clientFfiDir.set(rustDir.dir("client-ffi"))
        jniLibsDir.set(layout.buildDirectory.dir("rustJniLibs/android"))

        // Cargo performs its own incremental compilation, so always let it decide what to rebuild.
        outputs.upToDateWhen { false }
    }

// Custom task to run uniffi-bindgen
abstract class GenerateUniffiBindings
    @Inject
    constructor() : DefaultTask() {
        @get:InputFile
        abstract val libraryFile: RegularFileProperty

        @get:Internal
        abstract val rustProjectDir: DirectoryProperty

        @get:OutputDirectory
        abstract val outputDir: DirectoryProperty

        @get:Inject
        abstract val execOperations: ExecOperations

        @TaskAction
        fun generate() {
            val input = libraryFile.get().asFile
            val outDir = outputDir.get().asFile
            // Spawn a shell to run the command; fixes PATH race conditions that can cause
            // the cargo executable to not be found even though it is in the PATH.
            execOperations.exec {
                commandLine(
                    "sh",
                    "-c",
                    "cd ${rustProjectDir.get().asFile} && cargo run --bin uniffi-bindgen generate --library --language kotlin $input --out-dir $outDir",
                )
            }
        }
    }

val generateUniffiBindings =
    tasks.register<GenerateUniffiBindings>("generateUniffiBindings") {
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

        // UniFFI bindings are identical across ABIs, so we only need one libconnlib.so as input.
        // Point this task at an ABI that actually gets built when callers narrow the target list
        // via `android.injected.build.abi`. Defaults to x86_64 so the all-ABI build keeps working.
        val rustTargetTriple =
            targetAndroidAbi?.let { androidAbiToRustTriple(it) } ?: "x86_64-linux-android"

        libraryFile.fileValue(file("$cargoTargetDir/$rustTargetTriple/$profile/libconnlib.so"))
        rustProjectDir.set(rustDir)
        outputDir.set(layout.buildDirectory.dir("generated/source/uniffi/$profile"))
    }

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

// Wire the cargo build and uniffi outputs into every variant via the AGP variant API, which adds
// the generated directories as sources and carries the task dependencies automatically. AGP 9
// disallows adding task providers to the older source set API.
androidComponents {
    onVariants { variant ->
        variant.sources.jniLibs?.addGeneratedSourceDirectory(
            cargoBuild,
            CargoBuildTask::jniLibsDir,
        )
        variant.sources.kotlin?.addGeneratedSourceDirectory(
            generateUniffiBindings,
            GenerateUniffiBindings::outputDir,
        )
    }
}
