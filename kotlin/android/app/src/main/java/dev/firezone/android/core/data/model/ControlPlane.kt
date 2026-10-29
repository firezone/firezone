// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data.model

/**
 * The control plane the app signs in to: a Firezone Cloud deployment, or [CUSTOM] for any other URLs.
 *
 * The URLs of the Firezone Cloud control planes are compiled in and never taken from the control plane itself.
 */
enum class ControlPlane(
    val authUrl: String?,
    val apiUrl: String?,
) {
    CLOUD_US("https://app.firezone.dev", "wss://api.firezone.dev"),
    CLOUD_EU("https://eu.app.firezone.dev", "wss://eu.api.firezone.dev"),
    CUSTOM(null, null),
    ;

    companion object {
        /** The control plane whose URLs are [authUrl] and [apiUrl], or [CUSTOM]. */
        fun of(
            authUrl: String,
            apiUrl: String,
        ): ControlPlane =
            entries.firstOrNull { controlPlane ->
                controlPlane.authUrl != null &&
                    controlPlane.apiUrl != null &&
                    isSameUrl(controlPlane.authUrl, authUrl) &&
                    isSameUrl(controlPlane.apiUrl, apiUrl)
            } ?: CUSTOM

        // URLs are saved as typed or as an administrator wrote them, so a trailing slash, stray whitespace or a different case still matches.
        private fun isSameUrl(
            a: String,
            b: String,
        ): Boolean = a.trim().trimEnd('/').equals(b.trim().trimEnd('/'), ignoreCase = true)
    }
}
