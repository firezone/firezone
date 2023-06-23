plugins {
    id("org.mozilla.rust-android-gradle.rust-android")
    id("com.android.library")
    id("kotlin-android")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                groupId = "dev.firezone"
                artifactId = "connlib"
                version = "0.1.6"
                from(components["release"])
            }
        }
    }
}

publishing {
    repositories {
        maven {
            url = uri("https://maven.pkg.github.com/firezone/connlib")
            name = "GitHubPackages"
            credentials {
                username = System.getenv("GITHUB_ACTOR")
                password = System.getenv("GITHUB_TOKEN")
            }
        }
    }
}

android {
    namespace = "dev.firezone.connlib"
    compileSdk = 33

    defaultConfig {
        minSdk = 29
        targetSdk = 33
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    externalNativeBuild {
        cmake {
            version = "3.22.1"
        }
    }
    ndkVersion = "25.2.9519653"
    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility(JavaVersion.VERSION_1_8)
        targetCompatibility(JavaVersion.VERSION_1_8)
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }
    publishing {
        singleVariant("release")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.7.0")
    implementation("androidx.test.ext:junit-gtest:1.0.0-alpha01")
    implementation("com.android.ndk.thirdparty:googletest:1.11.0-beta-1")
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.jar"))))
    implementation("org.jetbrains.kotlin:kotlin-stdlib:1.7.21")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.3")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.4.0")
}

apply(plugin = "org.mozilla.rust-android-gradle.rust-android")

cargo {
    prebuiltToolchains = true
    verbose = true
    module  = "../"
    libname = "connlib"
    targets = listOf("arm", "arm64", "x86", "x86_64")
}

tasks.whenTaskAdded {
    if (name.startsWith("javaPreCompile")) {
        dependsOn(tasks.named("cargoBuild"))
    }
}
