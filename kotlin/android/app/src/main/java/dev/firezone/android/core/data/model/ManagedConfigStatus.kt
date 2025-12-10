// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.data.model

data class ManagedConfigStatus(
    val isAuthUrlManaged: Boolean,
    val isApiUrlManaged: Boolean,
    val isLogFilterManaged: Boolean,
    val isAccountSlugManaged: Boolean,
    val isStartOnLoginManaged: Boolean,
    val isConnectOnStartManaged: Boolean,
)
