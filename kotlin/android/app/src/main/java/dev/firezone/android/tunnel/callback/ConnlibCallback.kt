/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.callback

interface ConnlibCallback {
    fun onSetInterfaceConfig(tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddress: String, dnsFallbackStrategy: String): Int

    fun onTunnelReady(): Boolean

    fun onAddRoute(cidrAddress: String)

    fun onRemoveRoute(cidrAddress: String)

    fun onUpdateResources(resourceListJSON: String)

    fun onDisconnect(error: String?): Boolean

    fun onError(error: String): Boolean
}
