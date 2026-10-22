import groovy.json.JsonSlurper

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

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
                    "--no-deps",
                )
            }.standardOutput
            .asText
            .get(),
    ) as Map<*, *>

// Share the cargo target directory with app/build.gradle.kts via gradle extras so project
// scripts don't have to shell out to `cargo metadata` again at configuration time.
(gradle as ExtensionAware).extra["cargoTargetDir"] = cargoMetadata["target_directory"] as String

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Firezone App"
include(":app")
include(":dpc")
