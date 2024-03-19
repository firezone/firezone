// Top-level build file where you can add configuration options common to all sub-projects/modules.
buildscript {
    repositories {
        google()
        mavenCentral()
        maven(url = "https://jitpack.io")
        maven(url = "https://plugins.gradle.org/m2/")
    }

    dependencies {
        classpath("androidx.navigation:navigation-safe-args-gradle-plugin:2.7.7")
    }
}

plugins {
    id("org.jetbrains.kotlin.android") version "1.8.22" apply false
    id("com.android.application") version "8.3.0" apply false
    id("com.google.firebase.appdistribution") version "4.2.0" apply false
    id("com.google.dagger.hilt.android") version "2.51" apply false
    id("com.google.gms.google-services") version "4.4.1" apply false
    id("org.mozilla.rust-android-gradle.rust-android") version "0.9.3" apply false
    id("com.google.firebase.crashlytics") version "2.9.9" apply false
}

tasks.register("clean", Delete::class) {
    delete(layout.buildDirectory)
}
