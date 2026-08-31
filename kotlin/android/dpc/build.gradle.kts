plugins {
    id("com.android.application")
}

android {
    namespace = "dev.firezone.dpc"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.firezone.dpc"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
