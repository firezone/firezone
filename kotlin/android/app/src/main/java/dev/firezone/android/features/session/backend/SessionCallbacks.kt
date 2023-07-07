package dev.firezone.android.features.session.backend

import android.util.Log

public object SessionCallbacks {
    public fun onUpdateResources(resources: String): Boolean {
        // TODO: Call into client app to update resources list and routing table
        Log.d("Connlib", "onUpdateResources: $resources")

        return true
    }

    public fun onSetTunnelAddresses(addresses: String): Boolean {
        // TODO: // Call into client app to update interface addresses
        Log.d("Connlib", "onSetTunnelAddresses: $addresses")

        return true
    }
}
