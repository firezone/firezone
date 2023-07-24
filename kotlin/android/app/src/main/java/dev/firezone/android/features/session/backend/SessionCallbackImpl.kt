package dev.firezone.android.features.session.backend

import android.util.Log
import dev.firezone.connlib.SessionCallback

class SessionCallbackImpl: SessionCallback {

    override fun onConnect(addresses: String): Boolean {
        Log.d("Connlib", "onConnect: $addresses")

        return true
    }

    override fun onUpdateResources(resources: String): Boolean {
        // TODO: Call into client app to update resources list and routing table
        Log.d("Connlib", "onUpdateResources: $resources")

        return true
    }

    override fun onDisconnect(): Boolean {
        Log.d("Connlib", "onDisconnect")

        return true
    }
}
