package dev.firezone.connlib

interface SessionCallback {

    fun onSetInterfaceConfig(tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddress: String, dnsFallbackStrategy: String)

    fun onTunnelReady(): Boolean

    fun onAddRoute(cidrAddress: String)

    fun onRemoveRoute(cidrAddress: String)

    fun onUpdateResources(resourceListJSON: String)

    fun onDisconnect(error: String?): Boolean

    fun onError(error: String): Boolean
}
