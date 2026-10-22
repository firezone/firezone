// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import android.content.Context
import android.os.Build
import dev.firezone.android.BuildConfig
import io.sentry.Sentry
import io.sentry.android.core.SentryAndroid
import io.sentry.protocol.User

object Telemetry {
    private var environment: String? = null
    private var firezoneId: String? = null
    private var accountSlug: String? = null

    /**
     * Starts Sentry in the environment of `apiUrl`, or stops it for an API we don't run.
     *
     * Sentry hands the environment to its native layer at init, so changing it means initialising again.
     */
    @Synchronized
    fun start(
        context: Context,
        apiUrl: String,
    ) {
        if (BuildConfig.NO_TELEMETRY) {
            Log.i("Telemetry", "Telemetry is switched off for this build")
            return
        }

        val environment =
            when {
                apiUrl.startsWith("wss://api.firezone.dev") -> "production"
                apiUrl.startsWith("wss://api.firez.one") -> "staging"
                else -> null
            }
        if (environment == this.environment) return
        this.environment = environment

        if (environment == null) {
            Sentry.close()
            return
        }

        SentryAndroid.init(context) { options ->
            options.dsn =
                "https://928a6ee1f6af9734100b8bc89b2dc87d@sentry.firezone.dev/4508175126233088"
            options.environment = environment
            options.release = releaseName()
            options.dist = distributionType(context)
            options.logs.isEnabled = true
            options.isTombstoneEnabled = true
        }
        Sentry.setAttribute("process", "app")
    }

    fun setFirezoneId(id: String?) {
        firezoneId = id
        updateUser()
    }

    fun setAccountSlug(slug: String?) {
        accountSlug = slug
        updateUser()
    }

    private fun updateUser() {
        val id = firezoneId
        val slug = accountSlug

        if (id != null && slug != null) {
            val user =
                User().apply {
                    this.id = id
                    this.data = mapOf("account_slug" to slug)
                }
            Sentry.setUser(user)
            Sentry.setAttribute("user.account_slug", slug)
        } else {
            Sentry.setUser(null)
            Sentry.removeAttribute("user.account_slug")
        }
    }

    fun capture(error: Throwable) {
        Sentry.captureException(error)
    }

    private fun distributionType(context: Context): String =
        try {
            val installer =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
                } else {
                    @Suppress("DEPRECATION")
                    context.packageManager.getInstallerPackageName(context.packageName)
                }
            if (installer == "com.android.vending") "google_play" else "standalone"
        } catch (_: Exception) {
            "standalone"
        }

    private fun releaseName(): String {
        val version = BuildConfig.VERSION_NAME
        return "android-client@$version"
    }
}
