package dev.firezone.android.tunnel.callback

import dev.firezone.android.tunnel.model.Resource

interface TunnelListener {

    fun onSetInterfaceConfig(tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddress: String, dnsFallbackStrategy: String)

    fun onTunnelReady(): Boolean

    fun onAddRoute(cidrAddress: String)

    fun onRemoveRoute(cidrAddress: String)

    fun onUpdateResources(resources: List<Resource>)

    fun onDisconnect(error: String?): Boolean

    fun onError(error: String): Boolean
}
