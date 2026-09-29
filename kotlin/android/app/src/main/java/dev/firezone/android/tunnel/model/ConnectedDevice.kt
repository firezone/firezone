// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel.model

import android.os.Parcelable
import androidx.compose.runtime.Immutable
import kotlinx.parcelize.Parcelize

@Immutable
@Parcelize
data class ConnectedDevice(
    val id: String,
    val name: String,
    val slug: String,
    val tunIpv4: String,
    val tunIpv6: String,
) : Parcelable {
    val domain: String get() = slug + DOMAIN_SUFFIX

    companion object {
        // Appended to a device's slug to form the domain it answers DNS at.
        const val DOMAIN_SUFFIX = ".firezone.network"
    }
}
