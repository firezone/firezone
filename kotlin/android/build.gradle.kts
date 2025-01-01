// Top-level build file where you can add configuration options common to all sub-projects/modules.
buildscript {
    repositories {
        google()
        mavenCentral()
        maven(url = "https://jitpack.io")
        maven(url = "https://plugins.gradle.org/m2/")
    }

    dependencies {
        classpath("androidx.navigation:navigation-safe-args-gradle-plugin:2.8.5")
    }
}

plugins {
    id("org.mozilla.rust-android-gradle.rust-android") version "0.9.5" apply false
    id("org.jetbrains.kotlin.android") version "1.8.22" apply false
    id("com.android.application") version "8.7.2" apply false
    id("com.google.firebase.appdistribution") version "5.0.0" apply false
    id("com.google.dagger.hilt.android") version "2.54" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.2" apply false
}

tasks.register("clean", Delete::class) {
    delete(layout.buildDirectory)
}
