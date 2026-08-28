// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.app.Application
import android.content.Context
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.HiltAndroidApp
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.tunnel.TunnelService
import uniffi.connlib.ConnlibException
import uniffi.connlib.configureLogger
import uniffi.connlib.drainFlowLogs
import java.io.IOException
import javax.inject.Inject
import kotlin.concurrent.thread

@HiltAndroidApp
class FirezoneApp : Application() {
    @Inject
    internal lateinit var managedConfigurationSource: ManagedConfigurationSource

    override fun onCreate() {
        super.onCreate()

        managedConfigurationSource.start()

        // Initialize Telemetry as early as possible
        Telemetry.start(this)

        // Disable Crashlytics for debug builds
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(!BuildConfig.DEBUG)

        // Load the native library immediately after FirebaseCrashlytics
        // so we catch any issues with the native library early on.
        System.loadLibrary("connlib")

        // Wires connlib's TLS stack (rustls) to Android's trust store; required before any TLS handshake.
        initRustlsPlatformVerifier(this)

        val flowLogsDir = TunnelService.flowLogsDir(this)

        // The drain below runs without a session, so it never reaches `connect`.
        // Configure the logger here so that work is not silent. Best-effort: a
        // failure costs connlib's logs, not startup.
        try {
            configureLogger(TunnelService.logDir(this), BuildConfig.LOG_FILTER, flowLogsDir)
        } catch (e: ConnlibException) {
            Log.e(TAG, "Failed to configure connlib's logger", e)
            e.close()
        } catch (e: IOException) {
            Log.e(TAG, "Failed to configure connlib's logger", e)
        }

        // Drain flow logs whenever the app comes to the foreground (including this
        // launch): pokes the session's uploader while connected, or runs a bounded
        // one-shot pass to sweep up spool a previous session left behind. Off the
        // main thread because the one-shot case blocks for up to ten seconds.
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    thread(isDaemon = true) {
                        drainFlowLogs(flowLogsDir, TunnelService.protectSocketCallback)
                    }
                }
            },
        )
    }

    companion object {
        private const val TAG: String = "FirezoneApp"

        @JvmStatic
        external fun initRustlsPlatformVerifier(context: Context)
    }
}
