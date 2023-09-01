package dev.firezone.android.tunnel

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.provider.Settings
import android.util.Log
import com.google.firebase.installations.FirebaseInstallations
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.domain.preference.SaveIsConnectedUseCase
import dev.firezone.android.tunnel.callback.ConnlibCallback
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.callback.TunnelListener
import dev.firezone.android.tunnel.model.Tunnel
import dev.firezone.android.tunnel.model.TunnelConfig
import java.lang.ref.WeakReference
import java.nio.file.Files
import java.nio.file.Paths
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
@OptIn(ExperimentalStdlibApi::class)
internal class TunnelManager @Inject constructor(
    private val appContext: Context,
    private val getConfigUseCase: GetConfigUseCase,
    private val saveIsConnectedUseCase: SaveIsConnectedUseCase,
    private val moshi: Moshi,
) {

    private var activeTunnel: Tunnel? = null

    // TODO: Make this configurable in Settings UI
    private val debugMode = true

    private val listeners: MutableSet<WeakReference<TunnelListener>> = mutableSetOf()

    private val callback: ConnlibCallback = object: ConnlibCallback {
        override fun onUpdateResources(resourceListJSON: String) {
            // TODO: Call into client app to update resources list and routing table
            Log.d(TAG, "onUpdateResources: $resourceListJSON")
            moshi.adapter<List<Resource>>().fromJson(resourceListJSON)?.let { resources ->
                listeners.onEach {
                    it.get()?.onUpdateResources(resources)
                }
            }
        }

        override fun onSetInterfaceConfig(
            tunnelAddressIPv4: String,
            tunnelAddressIPv6: String,
            dnsAddress: String,
            dnsFallbackStrategy: String
        ): Int {
            Log.d(TAG, "onSetInterfaceConfig: [IPv4:$tunnelAddressIPv4] [IPv6:$tunnelAddressIPv6] [dns:$dnsAddress] [dnsFallbackStrategy:$dnsFallbackStrategy]")

            val tunnel = Tunnel(
                config = TunnelConfig(
                    tunnelAddressIPv4, tunnelAddressIPv6, dnsAddress, dnsFallbackStrategy
                )
            )

            listeners.onEach {
                it.get()?.onSetInterfaceConfig(tunnelAddressIPv4, tunnelAddressIPv6, dnsAddress, dnsFallbackStrategy)
            }

            return buildVpnService(tunnelAddressIPv4, tunnelAddressIPv6).establish()?.detachFd() ?: -1
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

    fun startVPN() {
        val intent = Intent(appContext, TunnelService::class.java)
        intent.action = TunnelService.ACTION_CONNECT
        appContext.startService(intent)
    }

    fun stopVPN() {
        val intent = Intent(appContext, TunnelService::class.java)
        intent.action = TunnelService.ACTION_DISCONNECT
        appContext.startService(intent)
    }

    fun connect() {
        try {
            val config = getConfigUseCase.sync()

            Log.d("Connlib", "accountId: ${config.accountId}")
            Log.d("Connlib", "token: ${config.token}")

            if (config.accountId != null && config.token != null) {
                Log.d("Connlib", "Attempting to establish TunnelSession...")
                sessionPtr = TunnelSession.connect(
                    controlPlaneUrl = BuildConfig.CONTROL_PLANE_URL,
                    token = config.token,
                    deviceId = deviceId(),
                    logDir = appContext.filesDir.absolutePath,
                    debugMode = debugMode,
                    callback = callback
                )
                Log.d("Connlib", "connlib session started! sessionPtr: ${sessionPtr}")
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

    private fun deviceId(): String {
        val deviceId = FirebaseInstallations
            .getInstance()
            .getId()

        Log.d("Connlib", "Device ID: ${deviceId}")

        return deviceId.toString()
     }

    private fun getLogDir(): String {
        // Create log directory if it doesn't exist
        val logDir = appContext.filesDir.absolutePath + "/log"
        Files.createDirectories(Paths.get(logDir))
        return logDir
    }

    private fun setConnectionStatus(value: Boolean) {
        saveIsConnectedUseCase.sync(value)
    }

    private fun buildVpnService(ipv4Address: String, ipv6Address: String): VpnService.Builder =
        TunnelService().Builder().apply {
            addAddress(ipv4Address, 32)
            addAddress(ipv6Address, 128)

            // TODO: These are the staging Resources. Remove these in favor of the onUpdateResources callback.
            addRoute("172.31.93.123", 32)
            addRoute("172.31.83.10", 32)
            addRoute("172.31.82.179", 32)

            setSession("Firezone VPN")

            // TODO: Can we do better?
            setMtu(1280)
        }

    internal companion object {
        var sessionPtr: Long? = null

        private const val TAG: String = "TunnelManager"

        init {
            Log.d("Connlib","Attempting to load library from main app...")
            System.loadLibrary("connlib")
            Log.d("Connlib","Library loaded from main app!")
        }
    }
}
