/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.model

import android.os.Parcelable
import kotlinx.parcelize.Parcelize

@Parcelize
data class TunnelConfig(
    val tunnelAddressIPv4: String? = null,
    val tunnelAddressIPv6: String? = null,
    val dnsAddresses: List<String> = emptyList(),
    val dnsFallbackStrategy: String = "upstream_resolver",
) : Parcelable
