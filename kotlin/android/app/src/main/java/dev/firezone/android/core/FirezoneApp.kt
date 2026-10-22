// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.app.Application
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.Lazy
import dagger.hilt.android.HiltAndroidApp
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.di.ApplicationScope
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import uniffi.connlib.ConnlibException
import uniffi.connlib.configureLogger
import uniffi.connlib.drainFlowLogs
import java.io.IOException
import javax.inject.Inject
import kotlin.concurrent.thread

@HiltAndroidApp
class FirezoneApp : Application() {
    @Inject
    internal lateinit var repo: Lazy<Repository>

    @Inject
    @ApplicationScope
    internal lateinit var applicationScope: CoroutineScope

    override fun onCreate() {
        super.onCreate()

        // Initialize Telemetry as early as possible. Reading the config touches the Keystore,
        // which can fail; that must not keep Sentry from reporting it.
        val config = runCatching { repo.get().getConfigSync() }.getOrNull()
        Telemetry.start(this, config?.apiUrl ?: BuildConfig.API_URL)

        // Disable Crashlytics for debug builds
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(!BuildConfig.DEBUG)

        // Load the native library immediately after FirebaseCrashlytics
        // so we catch any issues with the native library early on.
        System.loadLibrary("connlib")

        val flowLogsDir = TunnelService.flowLogsDir(this)

        // The drain below runs without a session, so it never reaches `connect`.
        // Configure the logger here so that work is not silent.
        applyLogFilter(config?.logFilter ?: BuildConfig.LOG_FILTER)

        // Settings edits and MDM pushes take effect without reconnecting.
        applicationScope.launch {
            repo.get().observeLogFilter().collect { applyLogFilter(it) }
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

    // Best-effort: a failure, such as a malformed filter, costs connlib's logs, not the app.
    private fun applyLogFilter(logFilter: String) {
        try {
            configureLogger(TunnelService.logDir(this), logFilter, TunnelService.flowLogsDir(this))
        } catch (e: ConnlibException) {
            Log.e(TAG, "Failed to configure connlib's logger", e)
            e.close()
        } catch (e: IOException) {
            Log.e(TAG, "Failed to configure connlib's logger", e)
        }
    }

    companion object {
        private const val TAG: String = "FirezoneApp"
    }
}
