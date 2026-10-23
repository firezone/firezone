// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data.model

/**
 * The Firezone Cloud deployment the app signs in to, or [CUSTOM] for any other URLs.
 *
 * The URLs of a region are compiled in and never taken from the portal: the region decides which portal the app talks to.
 */
enum class CloudRegion(
    val authUrl: String?,
    val apiUrl: String?,
) {
    US("https://app.firezone.dev", "wss://api.firezone.dev"),
    EU("https://eu.app.firezone.dev", "wss://eu.api.firezone.dev"),
    CUSTOM(null, null),
    ;

    companion object {
        /** The region whose URLs are [authUrl] and [apiUrl], or [CUSTOM]. */
        fun of(
            authUrl: String,
            apiUrl: String,
        ): CloudRegion =
            entries.firstOrNull { region ->
                region.authUrl != null &&
                    region.apiUrl != null &&
                    isSameUrl(region.authUrl, authUrl) &&
                    isSameUrl(region.apiUrl, apiUrl)
            } ?: CUSTOM

        // URLs are saved as typed or as an administrator wrote them, so a trailing slash, stray whitespace or a different case still matches.
        private fun isSameUrl(
            a: String,
            b: String,
        ): Boolean = a.trim().trimEnd('/').equals(b.trim().trimEnd('/'), ignoreCase = true)
    }
}
