package dev.firezone.android.tunnel

import android.net.VpnService
import android.util.Log

class TunnelCallbacks {
    fun onUpdateResources(resourceListJSON: String) {
        // TODO: Call into client app to update resources list and routing table
        Log.d(TunnelCallbacks.TAG, "onUpdateResources: $resourceListJSON")
    }

    fun onSetInterfaceConfig(
        tunnelAddressIPv4: String,
        tunnelAddressIPv6: String,
        dnsAddress: String,
        dnsFallbackStrategy: String,
    ): Int {
        Log.d(TunnelCallbacks.TAG, "onSetInterfaceConfig: [IPv4:$tunnelAddressIPv4] [IPv6:$tunnelAddressIPv6] [dns:$dnsAddress] [dnsFallbackStrategy:$dnsFallbackStrategy]")
        return buildVpnService(tunnelAddressIPv4, tunnelAddressIPv6).establish()?.detachFd() ?: -1
    }

    fun onTunnelReady(): Boolean {
        Log.d(TunnelCallbacks.TAG, "onTunnelReady")

        return true
    }

    fun onError(error: String): Boolean {
        Log.d(TunnelCallbacks.TAG, "onError: $error")

        return true
    }

    fun onAddRoute(cidrAddress: String) {
        Log.d(TunnelCallbacks.TAG, "onAddRoute: $cidrAddress")
    }

    fun onRemoveRoute(cidrAddress: String) {
        Log.d(TunnelCallbacks.TAG, "onRemoveRoute: $cidrAddress")
    }

    fun onDisconnect(error: String?): Boolean {
        Log.d(TunnelCallbacks.TAG, "onDisconnect $error")

        return true
    }
    private fun buildVpnService(ipv4Address: String, ipv6Address: String): VpnService.Builder =
        TunnelService().Builder().apply {
            addAddress(ipv4Address, 32)
            addAddress(ipv6Address, 128)

            // TODO: These are the staging Resources. Remove these in favor of the onUpdateResources callback.
            addRoute("172.31.93.123", 32)
            addRoute("172.31.83.10", 32)
            addRoute("172.31.82.179", 32)

            setSession("Firezone VPN")

            // TODO: Can we do better?
            setMtu(1280)
        }

    companion object {
        private const val TAG = "TunnelCallbacks"
    }
}
