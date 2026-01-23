// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.content.Context
import dev.firezone.android.BuildConfig
import io.sentry.Sentry
import io.sentry.android.core.SentryAndroid
import io.sentry.protocol.User

/**
 * Telemetry manager for Sentry integration.
 * Follows the pattern established in the Apple clients.
 */
object Telemetry {
    private var firezoneId: String? = null
    private var accountSlug: String? = null

    /**
     * Initialize Sentry as early as possible in the application lifecycle.
     */
    fun start(context: Context) {
        SentryAndroid.init(context) { options ->
            options.dsn =
                "https://66c71f83675f01abfffa8eb977bcbbf7@o4507971108339712.ingest.us.sentry.io/4508175177023488"
            options.environment = "entrypoint" // Will be reconfigured when API URL is available
            options.release = releaseName()
            options.dist = distributionType()
        }
    }

    /**
     * Set the Firezone ID (device ID) for telemetry.
     */
    fun setFirezoneId(id: String?) {
        firezoneId = id
        updateUser()
    }

    /**
     * Set the account slug for telemetry.
     */
    fun setAccountSlug(slug: String?) {
        accountSlug = slug
        updateUser()
    }

    /**
     * Update Sentry user context when we have both firezone ID and account slug.
     * Matches the format used in rust/telemetry/lib.rs and Swift clients.
     */
    private fun updateUser() {
        val id = firezoneId
        val slug = accountSlug

        if (id != null && slug != null) {
            val user = User().apply {
                this.id = id
                this.data = mapOf("account_slug" to slug)
            }
            Sentry.setUser(user)
        }
    }

    /**
     * Set the Sentry environment based on the API URL.
     * Disables Sentry for unknown environments.
     */
    fun setEnvironmentOrClose(apiUrl: String) {
        val environment = when {
            apiUrl.startsWith("wss://api.firezone.dev") -> "production"
            apiUrl.startsWith("wss://api.firez.one") -> "staging"
            else -> null
        }

        if (environment != null) {
            Sentry.configureScope { scope ->
                scope.environment = environment
            }
        } else {
            // Disable Sentry in unknown environments
            Sentry.close()
        }
    }

    /**
     * Capture an error/exception to Sentry.
     */
    fun capture(error: Throwable) {
        Sentry.captureException(error)
    }

    /**
     * Get the distribution type (google_play or standalone).
     */
    private fun distributionType(): String {
        // For Android, we could check the package installer to detect Google Play installation
        // For now, we'll return "standalone" as default
        // TODO: Implement proper detection using context.packageManager.getInstallerPackageName if needed
        return "standalone"
    }

    /**
     * Get the release name in the format "android-client@version".
     */
    private fun releaseName(): String {
        val version = BuildConfig.VERSION_NAME
        return "android-client@$version"
    }
}
