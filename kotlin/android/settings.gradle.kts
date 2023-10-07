pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Firezone App"
include(":app")
include(":connlib")
project(":connlib").projectDir = file("../../rust/connlib/clients/android/connlib")

buildCache {
    local {
        isEnabled = true
        directory = file("$rootDir/.gradle/build-cache")
    }
}
