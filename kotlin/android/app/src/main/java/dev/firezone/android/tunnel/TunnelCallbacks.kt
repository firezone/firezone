package dev.firezone.android.tunnel

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
        dnsFallbackStrategy: String
    ) {
        Log.d(TunnelCallbacks.TAG, "onSetInterfaceConfig: [IPv4:$tunnelAddressIPv4] [IPv6:$tunnelAddressIPv6] [dns:$dnsAddress] [dnsFallbackStrategy:$dnsFallbackStrategy]")
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

    companion object {
        private const val TAG = "TunnelCallbacks"
    }
}