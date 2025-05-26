/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.core.data.model

data class UserConfig(
    var authUrl: String,
    var apiUrl: String,
    var logFilter: String,
    var connectOnStart: Boolean,
)
