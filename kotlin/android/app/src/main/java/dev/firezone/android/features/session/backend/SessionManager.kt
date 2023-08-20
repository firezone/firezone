package dev.firezone.android.features.session.backend

import android.util.Log
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.domain.preference.SaveIsConnectedUseCase
import dev.firezone.connlib.Logger
import dev.firezone.connlib.Session
import dev.firezone.connlib.VpnService
import javax.inject.Inject

internal class SessionManager @Inject constructor(
    private val getConfigUseCase: GetConfigUseCase,
    private val saveIsConnectedUseCase: SaveIsConnectedUseCase,
) {
    private val callback: SessionCallbackImpl = SessionCallbackImpl()

    fun connect() {
        try {
            val config = getConfigUseCase.sync()

            Log.d("Connlib", "accountId: ${config.accountId}")
            Log.d("Connlib", "token: ${config.token}")

            if (config.accountId != null && config.token != null) {
                sessionPtr = Session.connect(
                    -1, // TODO: get fd from VpnService. See VpnBuilder#establish().detachFd()
                    BuildConfig.CONTROL_PLANE_URL,
                    config.token,
                    callback
                )
                setConnectionStatus(true)
            }
        } catch (exception: Exception) {
            Log.e("Connection error:", exception.message.toString())
        }
    }

    fun disconnect() {
        try {
            Session.disconnect(sessionPtr!!)
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
            System.loadLibrary("connlib")
            Logger.init()
            Log.d("Connlib","Library loaded from main app!")
        }
    }
}
