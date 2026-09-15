// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
    id("com.android.application") version "9.3.2" apply false
    id("com.google.devtools.ksp") version "2.3.11" apply false
    id("com.google.dagger.hilt.android") version "2.60.1" apply false
    id("com.google.gms.google-services") version "4.5.0" apply false
    id("com.google.firebase.crashlytics") version "3.0.8" apply false
    id("io.github.takahirom.roborazzi") version "1.72.0" apply false
    // `:app` and `:dpc` both apply this, and the build service spotless registers is shared
    // between them, so the plugin has to be loaded once here rather than once per project.
    id("com.diffplug.spotless") version "8.10.0" apply false
}

tasks.register("clean", Delete::class) {
    delete(layout.buildDirectory)
}
