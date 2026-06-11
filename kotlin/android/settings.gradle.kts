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
// into the APK. The crate ships it as a local Maven repo inside its source; resolve its
// path and version via cargo metadata so they always match the Rust dependency.
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
            url =
                File(rustlsAndroidPackage["manifest_path"] as String)
                    .parentFile
                    .resolve("maven")
                    .toURI()
            metadataSources { mavenPom() }
            content { includeGroup("rustls") }
        }
    }
    versionCatalogs {
        create("cargo") {
            library("rustls-platform-verifier", "rustls", "rustls-platform-verifier")
                .version(rustlsAndroidPackage["version"] as String)
        }
    }
}

rootProject.name = "Firezone App"
include(":app")

buildCache {
    local {
        isEnabled = true
        directory = file("$rootDir/.gradle/build-cache")
    }
}
