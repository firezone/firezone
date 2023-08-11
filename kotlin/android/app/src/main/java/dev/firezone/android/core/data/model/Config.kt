package dev.firezone.android.core.data.model

internal data class Config(
    val portalUrl: String?,
    val isConnected: Boolean = false,
    val jwt: String?,
)
