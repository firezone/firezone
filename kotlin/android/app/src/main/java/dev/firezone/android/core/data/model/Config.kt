package dev.firezone.android.core.data.model

internal data class Config(
    val accountId: String?,
    val isConnected: Boolean = false,
    val token: String?,
)
