package dev.firezone.android.features.session.backend

import android.content.SharedPreferences
import android.util.Log
import dev.firezone.connlib.Session
import dev.firezone.connlib.Logger
import javax.inject.Inject

private const val PORTAL_URL_KEY = "portalUrl"
private const val AUTH_TOKEN_KEY = "authToken"

internal class SessionManager @Inject constructor(
    private val sharedPreferences: SharedPreferences
) {
    internal companion object {
        var sessionPtr: Long? = null
        init {
            System.loadLibrary("connlib")
            Logger.init()
            Log.d("Connlib","Library loaded from main app!")
        }
    }

    fun connect() {
        val portalUrl = sharedPreferences.getString(PORTAL_URL_KEY, null)
        val portalToken = sharedPreferences.getString(AUTH_TOKEN_KEY, null)
        try {
            Log.d("Connlib", portalUrl.toString())
            Log.d("Connlib", portalToken.toString())

            sessionPtr = Session.connect(
                portalUrl!!,
                portalToken!!,
                SessionCallbacks
            )
            setConnectionStatus(true)
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
        sharedPreferences.edit().putBoolean("isConnected", value).apply()
    }
}
