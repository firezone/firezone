/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.tunnel.callback.TunnelListener
import dev.firezone.android.tunnel.data.TunnelRepository
import java.lang.ref.WeakReference
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
internal class TunnelManager
    @Inject
    constructor(
        private val appContext: Context,
        private val tunnelRepository: TunnelRepository,
        private val preferenceRepository: PreferenceRepository,
    ) {
        private val listeners: MutableSet<WeakReference<TunnelListener>> = mutableSetOf()

        private val tunnelRepositoryListener =
            SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                when (key) {
                    TunnelRepository.STATE_KEY -> {
                        listeners.forEach {
                            it.get()?.onTunnelStateUpdate(tunnelRepository.getState())
                        }
                    }
                    TunnelRepository.RESOURCES_KEY -> {
                        listeners.forEach {
                            it.get()?.onResourcesUpdate(tunnelRepository.getResources())
                        }
                    }
                }
            }

        fun addListener(listener: TunnelListener) {
            val contains =
                listeners.any {
                    it.get() == listener
                }

            if (!contains) {
                listeners.add(WeakReference(listener))
            }

            tunnelRepository.addListener(tunnelRepositoryListener)
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
            clearSessionData()
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

        private fun clearSessionData() {
            preferenceRepository.clearToken()
            tunnelRepository.clearAll()
        }

        internal companion object {
            private const val TAG: String = "TunnelManager"
        }
    }
