// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.app.Application
import android.content.Context
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.HiltAndroidApp
import dev.firezone.android.BuildConfig
import dev.firezone.android.tunnel.TunnelService
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

        // Best-effort flow-log drain on launch for spool a previous session left behind.
        // Only when the tunnel isn't running: there's then no VPN to bypass, so plain
        // (unprotected) sockets are fine. While connected, the TunnelService's protected
        // uploader owns draining.
        if (!TunnelService.isRunning(this)) {
            val flowLogsDir = filesDir.absolutePath + "/flow_logs"
            thread(isDaemon = true) { runFlowLogUpload(flowLogsDir) }
        }
    }

    companion object {
        @JvmStatic
        external fun initRustlsPlatformVerifier(context: Context)
    }
}
