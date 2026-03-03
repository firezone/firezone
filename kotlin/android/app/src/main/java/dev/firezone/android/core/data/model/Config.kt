// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.data.model

data class Config(
    val authUrl: String,
    val apiUrl: String,
    val logFilter: String,
    val accountSlug: String,
    val startOnLogin: Boolean,
    val connectOnStart: Boolean,
)
