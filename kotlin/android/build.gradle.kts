// Top-level build file where you can add configuration options common to all sub-projects/modules.
buildscript {
    repositories {
        google()
        mavenCentral()
        maven(url = "https://jitpack.io")
        maven(url = "https://plugins.gradle.org/m2/")
    }
    dependencies {
        // Should support Gradle version
        // See https://developer.android.com/build/releases/gradle-plugin
        classpath("com.android.tools.build:gradle:8.1.2")

        // Should match Kotlin compiler version
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.10")
        classpath("com.google.dagger:hilt-android-gradle-plugin:2.44.1")
        classpath("com.google.android.libraries.mapsplatform.secrets-gradle-plugin:secrets-gradle-plugin:2.0.1")
        classpath("androidx.navigation:navigation-safe-args-gradle-plugin:2.5.3")
        classpath("org.mozilla.rust-android-gradle:plugin:0.9.3")
        classpath("com.google.gms:google-services:4.3.15")
        classpath("com.google.firebase:firebase-crashlytics-gradle:2.9.8")
    }
}

plugins {
    id("com.google.firebase.appdistribution") version "4.0.0" apply false
}

tasks.register("clean", Delete::class) {
    delete(rootProject.buildDir)
}
