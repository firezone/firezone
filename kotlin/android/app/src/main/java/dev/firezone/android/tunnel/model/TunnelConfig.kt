package dev.firezone.android.tunnel.model

data class TunnelConfig (
    val tunnelAddressIPv4: String,
    val tunnelAddressIPv6: String,
    val dnsAddress: String,
    val dnsFallbackStrategy: String,
)
