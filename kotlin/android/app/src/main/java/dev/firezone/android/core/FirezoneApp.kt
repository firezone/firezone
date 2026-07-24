// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.app.Application
import android.content.Context
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.HiltAndroidApp
import dev.firezone.android.BuildConfig
import uniffi.connlib.ensureFlowLogUploader

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

        // Wires connlib's TLS stack (rustls) to Android's trust store; required before any TLS handshake.
        initRustlsPlatformVerifier(this)

        // Run the flow-log uploader for the app-process lifetime so spool a previous
        // session left behind uploads promptly. Safe in every state: connlib sessions
        // install their VPN-protected sockets into it while they live.
        ensureFlowLogUploader(filesDir.absolutePath + "/flow_logs")
    }

    companion object {
        @JvmStatic
        external fun initRustlsPlatformVerifier(context: Context)
    }
}
