package dev.firezone.android.core.data

internal data class Config(
    var portalUrl: String?,
    var isConnected: Boolean = false,
    var jwt: String?,
)
