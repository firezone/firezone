# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Preserve file and line number information so Crashlytics and Play Console
# can show readable, deobfuscated stack traces.
-keepattributes SourceFile,LineNumberTable

# rustls-platform-verifier's Kotlin component is only reached via JNI from
# libconnlib.so, so R8 sees no references to it and would strip it.
-keep,includedescriptorclasses class org.rustls.platformverifier.** { *; }

# The UniFFI-generated bindings are loaded through JNA, which resolves classes,
# fields and native methods reflectively by name at runtime.
-keep,includedescriptorclasses class uniffi.connlib.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.* { public *; }
-dontwarn java.awt.*

# Tunnel models are deserialized reflectively by Moshi's KotlinJsonAdapterFactory,
# which reads Kotlin metadata through kotlin-reflect.
-keep class dev.firezone.android.tunnel.model.** { *; }
-keepclassmembers class kotlin.Metadata {
    public <methods>;
}

# Persisted to SharedPreferences via Gson by constant name; renaming the
# constants would corrupt existing installs on update.
-keep class dev.firezone.android.core.data.ResourceState { *; }
