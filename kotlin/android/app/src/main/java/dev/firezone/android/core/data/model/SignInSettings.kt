// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data.model

/** The settings a sign-in uses; changing any of them only takes effect at the next sign-in. */
data class SignInSettings(
    val accountSlug: String,
    val authUrl: String,
    val apiUrl: String,
)

fun Config.signInSettings(): SignInSettings = SignInSettings(accountSlug, authUrl, apiUrl)
