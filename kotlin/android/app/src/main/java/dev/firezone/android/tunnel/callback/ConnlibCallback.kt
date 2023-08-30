package dev.firezone.android.tunnel.callback

interface ConnlibCallback {
    fun onSetInterfaceConfig(tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddress: String, dnsFallbackStrategy: String): Int

    fun onTunnelReady(): Boolean

    fun onAddRoute(cidrAddress: String): Int

    fun onRemoveRoute(cidrAddress: String): Int

    fun onUpdateResources(resourceListJSON: String): Int

    fun onDisconnect(error: String?): Boolean

    fun onError(error: String): Boolean
}
