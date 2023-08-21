package dev.firezone.android.features.session.backend

import android.net.VpnService
import android.util.Log
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.domain.preference.SaveIsConnectedUseCase
import dev.firezone.android.tunnel.TunnelLogger
import dev.firezone.android.tunnel.TunnelSession
import dev.firezone.android.tunnel.TunnelManager
import dev.firezone.android.tunnel.TunnelService
import javax.inject.Inject

internal class SessionManager @Inject constructor(
    private val getConfigUseCase: GetConfigUseCase,
    private val saveIsConnectedUseCase: SaveIsConnectedUseCase,
) {
    private val callback: TunnelManager = TunnelManager()

    fun connect() {
        try {
            val config = getConfigUseCase.sync()

            Log.d("Connlib", "accountId: ${config.accountId}")
            Log.d("Connlib", "token: ${config.token}")

            if (config.accountId != null && config.token != null) {
                buildVpnService().establish()?.let {
                    sessionPtr = TunnelSession.connect(
                        it.fd,
                        BuildConfig.CONTROL_PLANE_URL,
                        config.token,
                        callback
                    )
                    Log.d("Connlib", "sessionPtr: $sessionPtr")
                    setConnectionStatus(true)
                } ?: let {
                    Log.d("Connlib", "Failed to build VpnService")
                }
            }
        } catch (exception: Exception) {
            Log.e("Connection error:", exception.message.toString())
        }
    }

    fun disconnect() {
        try {
            TunnelSession.disconnect(sessionPtr!!)
            setConnectionStatus(false)
        } catch (exception: Exception) {
            Log.e("Disconnection error:", exception.message.toString())
        }
    }

    private fun setConnectionStatus(value: Boolean) {
        saveIsConnectedUseCase.sync(value)
    }

    private fun buildVpnService():VpnService.Builder =
        TunnelService().Builder().apply {
            setSession("Firezone VPN")
            setMtu(1280)
        }

    internal companion object {
        var sessionPtr: Long? = null
        init {
            Log.d("Connlib","Attempting to load library from main app...")
            System.loadLibrary("connlib")
            Log.d("Connlib","Attempting to TunnelLogger.init()!")
            TunnelLogger.init()
            Log.d("Connlib","Library loaded from main app!")
        }
    }
}
