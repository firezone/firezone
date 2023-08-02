package dev.firezone.android.features.session.backend

import android.util.Log
import dev.firezone.connlib.SessionCallback

class SessionCallbackImpl: SessionCallback {

    override fun onUpdateResources(resources: String) {
        // TODO: Call into client app to update resources list and routing table
        Log.d(TAG, "onUpdateResources: $resources")
    }

    override fun onSetInterfaceConfig(
        tunnelAddressIPv4: String,
        tunnelAddressIPv6: String,
        dnsAddress: String,
        dnsFallbackStrategy: String
    ) {
        Log.d(TAG, "onSetInterfaceConfig: [IPv4:$tunnelAddressIPv4] [IPv6:$tunnelAddressIPv6] [dns:$dnsAddress]")
    }

    override fun onTunnelReady(): Boolean {
        Log.d(TAG, "onTunnelReady")
        return true
    }

    override fun onError(error: String): Boolean {
        Log.d(TAG, "onError: $error")
        return true
    }

    override fun onAddRoute(cidrAddress: String) {
        Log.d(TAG, "onAddRoute: $cidrAddress")
    }

    override fun onRemoveRoute(cidrAddress: String) {
        Log.d(TAG, "onRemoveRoute: $cidrAddress")
    }

    override fun onDisconnect(error: String?): Boolean {
        Log.d(TAG, "onDisconnect $error")
        return true
    }

    companion object {
        private const val TAG: String = "ConnlibCallback"
    }
}
