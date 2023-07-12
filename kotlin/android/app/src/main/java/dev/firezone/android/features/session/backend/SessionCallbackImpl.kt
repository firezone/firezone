package dev.firezone.android.features.session.backend

import android.util.Log
import dev.firezone.connlib.session.SessionCallback

class SessionCallbackImpl: SessionCallback {

    override fun onConnect(addresses: String): Boolean {
        Log.d("Connlib", "status: $: $status")

        return true
    }

    override fun onUpdateResources(resources: String): Boolean {
        // TODO: Call into client app to update resources list and routing table
        Log.d("Connlib", "onUpdateResources: $resources")

        return true
    }

    override fun onDisconnect(): Boolean {
        // TODO: // Call into client app to update interface addresses
        Log.d("Connlib", "onSetTunnelAddresses: $addresses")

        return true
    }
}
