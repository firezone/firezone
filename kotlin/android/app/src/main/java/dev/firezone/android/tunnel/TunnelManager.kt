package dev.firezone.android.tunnel

import android.util.Log
import java.lang.ref.WeakReference

class TunnelManager {

    private var activeTunnel: Tunnel? = null

    private val listeners: MutableSet<WeakReference<TunnelListener>> = mutableSetOf()

    private val callback: TunnelListener = object: TunnelListener {
        override fun onUpdateResources(resourceListJSON: String) {
            // TODO: Call into client app to update resources list and routing table
            Log.d(TAG, "onUpdateResources: $resourceListJSON")
            listeners.onEach {
                it.get()?.onUpdateResources(resourceListJSON)
            }
        }

        override fun onSetInterfaceConfig(
            tunnelAddressIPv4: String,
            tunnelAddressIPv6: String,
            dnsAddress: String,
            dnsFallbackStrategy: String
        ) {
            Log.d(TAG, "onSetInterfaceConfig: [IPv4:$tunnelAddressIPv4] [IPv6:$tunnelAddressIPv6] [dns:$dnsAddress]")

            listeners.onEach {
                it.get()?.onSetInterfaceConfig(tunnelAddressIPv4, tunnelAddressIPv6, dnsAddress, dnsFallbackStrategy)
            }
        }

        override fun onTunnelReady(): Boolean {
            Log.d(TAG, "onTunnelReady")

            listeners.onEach {
                it.get()?.onTunnelReady()
            }
            return true
        }

        override fun onError(error: String): Boolean {
            Log.d(TAG, "onError: $error")

            listeners.onEach {
                it.get()?.onError(error)
            }
            return true
        }

        override fun onAddRoute(cidrAddress: String) {
            Log.d(TAG, "onAddRoute: $cidrAddress")

            listeners.onEach {
                it.get()?.onAddRoute(cidrAddress)
            }
        }

        override fun onRemoveRoute(cidrAddress: String) {
            Log.d(TAG, "onRemoveRoute: $cidrAddress")

            listeners.onEach {
                it.get()?.onRemoveRoute(cidrAddress)
            }
        }

        override fun onDisconnect(error: String?): Boolean {
            Log.d(TAG, "onDisconnect $error")

            listeners.onEach {
                it.get()?.onDisconnect(error)
            }
            return true
        }
    }

    fun addListener(listener: TunnelListener) {
        val contains = listeners.any {
            it.get() == listener
        }

        if (!contains) {
            listeners.add(WeakReference(listener))
        }
    }

    fun removeListener(listener: TunnelListener) {
        listeners.firstOrNull {
            it.get() == listener
        }?.let {
            it.clear()
            listeners.remove(it)
        }
    }

    companion object {
        private const val TAG: String = "TunnelManager"
    }
}
