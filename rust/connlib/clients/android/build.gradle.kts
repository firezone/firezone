plugins {
    id("org.mozilla.rust-android-gradle.rust-android") version "0.9.3"
    id("com.android.library") version "7.4.2" apply false
    id("org.jetbrains.kotlin.android") version "1.7.21" apply false
}

tasks.register("clean",Delete::class) {
    delete(rootProject.buildDir)
}
