package dev.firezone.android.tunnel

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import dev.firezone.android.tunnel.callback.TunnelListener
import dev.firezone.android.tunnel.data.TunnelRepository
import dev.firezone.android.tunnel.model.Tunnel
import java.lang.ref.WeakReference
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
internal class TunnelManager @Inject constructor(
    private val appContext: Context,
    private val tunnelRepository: TunnelRepository,
) {

    private val listeners: MutableSet<WeakReference<TunnelListener>> = mutableSetOf()

    private val tunnelRepositoryListener = SharedPreferences.OnSharedPreferenceChangeListener { _, s ->
        if (s == TunnelRepository.RESOURCES_KEY) {
            listeners.forEach {
                it.get()?.onResourcesUpdate(tunnelRepository.getResources())
            }
        }
    }

    fun addListener(listener: TunnelListener) {
        val contains = listeners.any {
            it.get() == listener
        }

        if (!contains) {
            listeners.add(WeakReference(listener))
        }

        tunnelRepository.addListener(tunnelRepositoryListener)
        tunnelRepository.setState(Tunnel.State.Connecting)
    }

    fun removeListener(listener: TunnelListener) {
        listeners.firstOrNull {
            it.get() == listener
        }?.let {
            it.clear()
            listeners.remove(it)
        }

        if (listeners.isEmpty()) {
            tunnelRepository.removeListener(tunnelRepositoryListener)
        }
    }

    fun connect() {
        startVPNService()
    }

    fun disconnect() {
        stopVPNService()
    }

    private fun startVPNService() {
        val intent = Intent(appContext, TunnelService::class.java)
        intent.action = TunnelService.ACTION_CONNECT
        appContext.startService(intent)
    }

    private fun stopVPNService() {
        val intent = Intent(appContext, TunnelService::class.java)
        intent.action = TunnelService.ACTION_DISCONNECT
        appContext.startService(intent)
    }

    internal companion object {
        private const val TAG: String = "TunnelManager"

        init {
            Log.d(TAG,"Attempting to load library from main app...")
            System.loadLibrary("connlib")
            Log.d(TAG,"Library loaded from main app!")
        }
    }
}
