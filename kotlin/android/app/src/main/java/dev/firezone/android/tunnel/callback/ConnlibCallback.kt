/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.callback

interface ConnlibCallback {
    fun onSetInterfaceConfig(
        tunnelAddressIPv4: String,
        tunnelAddressIPv6: String,
        dnsAddress: String,
    ): Int

    fun onTunnelReady(): Boolean

    fun onAddRoute(
        addr: String,
        prefix: Int,
    ): Int

    fun onRemoveRoute(
        addr: String,
        prefix: Int,
    ): Int

    fun onUpdateResources(resourceListJSON: String)

    fun onDisconnect(error: String?): Boolean

    fun getSystemDefaultResolvers(): Array<ByteArray>
}
