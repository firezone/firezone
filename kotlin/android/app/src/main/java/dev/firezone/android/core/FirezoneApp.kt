// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.app.Application
import android.content.Context
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.HiltAndroidApp
import dev.firezone.android.BuildConfig
import uniffi.connlib.runFlowLogUpload
import kotlin.concurrent.thread

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

        // Drain flow logs a previous session left spooled. One-shot on purpose: the
        // interval uploader lives inside connlib sessions, and with no session there
        // is nothing producing flows, so a resident thread would poll and dial for
        // nothing. Plain sockets are fine because no VPN of ours is up yet.
        val flowLogsDir = filesDir.absolutePath + "/flow_logs"
        thread(isDaemon = true) { runFlowLogUpload(flowLogsDir) }
    }

    companion object {
        @JvmStatic
        external fun initRustlsPlatformVerifier(context: Context)
    }
}
