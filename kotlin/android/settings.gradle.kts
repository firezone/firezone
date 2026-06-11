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
fun rustlsPlatformVerifierAndroidPackage(): Map<*, *> {
    val metadataText =
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
            .get()

    val metadata = JsonSlurper().parseText(metadataText) as Map<*, *>
    val packages = (metadata["packages"] as List<*>).filterIsInstance<Map<*, *>>()
    return packages.firstOrNull { it["name"] == "rustls-platform-verifier-android" }
        ?: throw GradleException("rustls-platform-verifier-android not found in cargo metadata")
}

val rustlsAndroidPackage = rustlsPlatformVerifierAndroidPackage()

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
