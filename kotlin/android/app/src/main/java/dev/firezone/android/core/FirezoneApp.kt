// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.app.Application
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.HiltAndroidApp
import dev.firezone.android.BuildConfig

@HiltAndroidApp
class FirezoneApp : Application() {
    override fun onCreate() {
        super.onCreate()

        // Initialize Telemetry as early as possible
        Telemetry.start(this)

        // Disable Crashlytics for debug builds
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(!BuildConfig.DEBUG)

        // Load the native library immediately after FirebaseCrashlytics
        // so we catch any issues with the native library early on.
        System.loadLibrary("connlib")
    }
}
