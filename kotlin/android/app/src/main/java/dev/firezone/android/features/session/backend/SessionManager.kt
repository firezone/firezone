package dev.firezone.android.features.session.backend

import android.net.VpnService
import android.util.Log
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
                Log.d("Connlib", "Attempting to establish VPN connection...")
                buildVpnService().establish()?.let {
                    Log.d("Connlib", "VPN connection established! Attempting to start connlib session...")
                    sessionPtr = TunnelSession.connect(
                        it.detachFd(),
                        BuildConfig.CONTROL_PLANE_URL,
                        config.token,
                        TunnelCallbacks()
                    )
                    Log.d("Connlib", "connlib session started! sessionPtr: $sessionPtr")
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

    private fun buildVpnService(): VpnService.Builder =
        TunnelService().Builder().apply {
            // Add a dummy address for now. Needed for the "establish" call to succeed.
            // TODO: Remove these in favor of connecting the TunnelSession *without* the fd, and then
            // returning the fd in the onSetInterfaceConfig callback. This is being worked on by @conectado
            addAddress("100.100.111.1", 32)
            addAddress("fd00:2021:1111::100:100:111:1", 128)

            // TODO: These are the staging Resources. Remove these in favor of the onUpdateResources callback.
            addRoute("172.31.93.123", 32)
            addRoute("172.31.83.10", 32)
            addRoute("172.31.82.179", 32)

            setSession("Firezone VPN")
            setMtu(1280)
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
