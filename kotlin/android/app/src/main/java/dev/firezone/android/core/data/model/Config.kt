// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.data.model

data class Config(
    var authUrl: String,
    var apiUrl: String,
    var logFilter: String,
    var accountSlug: String,
    var startOnLogin: Boolean,
    var connectOnStart: Boolean,
)
