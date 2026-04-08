// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import android.content.Context
import android.os.Build
import dev.firezone.android.BuildConfig
import io.sentry.Sentry
import io.sentry.android.core.SentryAndroid
import io.sentry.protocol.User

object Telemetry {
    private var firezoneId: String? = null
    private var accountSlug: String? = null

    fun start(context: Context) {
        SentryAndroid.init(context) { options ->
            options.dsn =
                "https://928a6ee1f6af9734100b8bc89b2dc87d@sentry.firezone.dev/4508175126233088"
            options.environment = "entrypoint"
            options.release = releaseName()
            options.dist = distributionType(context)
            options.logs.isEnabled = true
        }
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
            Log.setUser(id, slug)
            val user =
                User().apply {
                    this.id = id
                    this.data = mapOf("account_slug" to slug)
                }
            Sentry.setUser(user)
        } else {
            Log.clearUser()
            Sentry.setUser(null)
        }
    }

    fun setEnvironmentOrClose(apiUrl: String) {
        val environment =
            when {
                apiUrl.startsWith("wss://api.firezone.dev") -> "production"
                apiUrl.startsWith("wss://api.firez.one") -> "staging"
                else -> null
            }

        if (environment != null) {
            Log.setEnvironment(environment)
            Sentry.getCurrentScopes().options.environment = environment
        } else {
            Sentry.close()
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
