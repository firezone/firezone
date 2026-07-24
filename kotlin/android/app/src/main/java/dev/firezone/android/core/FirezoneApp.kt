// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.app.Application
import android.content.Context
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.HiltAndroidApp
import dev.firezone.android.BuildConfig
import uniffi.connlib.drainFlowLogs
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

        // Drain flow logs whenever the app comes to the foreground (including this
        // launch): pokes the session's uploader while connected, or runs a bounded
        // one-shot pass to sweep up spool a previous session left behind. Off the
        // main thread because the one-shot case blocks for up to ten seconds.
        val flowLogsDir = filesDir.absolutePath + "/flow_logs"
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    thread(isDaemon = true) { drainFlowLogs(flowLogsDir) }
                }
            },
        )
    }

    companion object {
        @JvmStatic
        external fun initRustlsPlatformVerifier(context: Context)
    }
}
