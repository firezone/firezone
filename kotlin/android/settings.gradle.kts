import groovy.json.JsonSlurper

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// rustls-platform-verifier delegates connlib's TLS certificate verification to a small
// Kotlin component (org.rustls.platformverifier.CertificateVerifier) that must be bundled
// into the APK. Upstream publishes it to a Maven repo hosted on GitHub; resolve its version
// via cargo metadata so it always matches the Rust dependency.
val cargoMetadata: Map<*, *> =
    JsonSlurper().parseText(
        providers
            .exec {
                workingDir = File(rootDir, "../../rust")
                commandLine(
                    "cargo",
                    "metadata",
                    "--format-version",
                    "1",
                    "--filter-platform",
                    "aarch64-linux-android",
                )
            }.standardOutput
            .asText
            .get(),
    ) as Map<*, *>

// Share the cargo target directory with app/build.gradle.kts via gradle extras so project
// scripts don't have to shell out to `cargo metadata` again at configuration time.
(gradle as ExtensionAware).extra["cargoTargetDir"] = cargoMetadata["target_directory"] as String

val rustlsAndroidPackage =
    (cargoMetadata["packages"] as List<*>)
        .filterIsInstance<Map<*, *>>()
        .firstOrNull { it["name"] == "rustls-platform-verifier-android" }
        ?: throw GradleException("rustls-platform-verifier-android not found in cargo metadata")

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven {
            // Pinned to a commit of upstream's `maven-archive` branch, which could otherwise change the AAR
            // under a locked version. Move it forward whenever `rustls-platform-verifier-android` is bumped.
            url = uri("https://raw.githubusercontent.com/rustls/rustls-platform-verifier/1aa691352a5e0c215210dfc9a3c2f2078639dc91/android-release-support/maven/")
            metadataSources { mavenPom() }
            content { includeGroup("org.rustls") }
        }
    }
    versionCatalogs {
        create("cargo") {
            library("rustls-platform-verifier", "org.rustls", "rustls-platform-verifier")
                .version(rustlsAndroidPackage["version"] as String)
        }
    }
}

rootProject.name = "Firezone App"
include(":app")
include(":dpc")
