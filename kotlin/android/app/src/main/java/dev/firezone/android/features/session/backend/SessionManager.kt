package dev.firezone.android.features.session.backend

import android.net.VpnService
import android.util.Log
import android.provider.Settings
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.domain.preference.SaveIsConnectedUseCase
import dev.firezone.android.tunnel.TunnelCallbacks
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
                Log.d("Connlib", "Attempting to establish TunnelSession...")
                sessionPtr = TunnelSession.connect(
                    BuildConfig.CONTROL_PLANE_URL,
                    config.token,
                    Settings.Secure.ANDROID_ID,
                    TunnelCallbacks()
                )
                Log.d("Connlib", "connlib session started! sessionPtr: $sessionPtr")
                setConnectionStatus(true)
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



    internal companion object {
        var sessionPtr: Long? = null
        init {
            Log.d("Connlib","Attempting to load library from main app...")
            System.loadLibrary("connlib")
            Log.d("Connlib","Library loaded from main app!")
            TunnelLogger.init()
            Log.d("Connlib","Connlib Logger initialized!")
        }
    }
}
