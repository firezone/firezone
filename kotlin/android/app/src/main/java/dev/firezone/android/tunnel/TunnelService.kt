/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.system.OsConstants
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.installations.FirebaseInstallations
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.tunnel.callback.ConnlibCallback
import dev.firezone.android.tunnel.data.TunnelRepository
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.Tunnel
import dev.firezone.android.tunnel.model.TunnelConfig
import dev.firezone.android.tunnel.util.DnsServersDetector
import java.nio.file.Files
import java.nio.file.Paths
import javax.inject.Inject

@AndroidEntryPoint
@OptIn(ExperimentalStdlibApi::class)
class TunnelService : VpnService() {
    @Inject
    internal lateinit var getConfigUseCase: GetConfigUseCase

    @Inject
    internal lateinit var tunnelRepository: TunnelRepository

    @Inject
    internal lateinit var preferenceRepository: PreferenceRepository

    @Inject
    internal lateinit var moshi: Moshi

    private var sessionPtr: Long? = null

    private var shouldReconnect: Boolean = false

    private val activeTunnel: Tunnel?
        get() = tunnelRepository.get()

    private val callback: ConnlibCallback =
        object : ConnlibCallback {
            override fun onUpdateResources(resourceListJSON: String) {
                Log.d(TAG, "onUpdateResources: $resourceListJSON")
                moshi.adapter<List<Resource>>().fromJson(resourceListJSON)?.let { resources ->
                    tunnelRepository.setResources(resources)
                }
            }

            override fun onSetInterfaceConfig(
                tunnelAddressIPv4: String,
                tunnelAddressIPv6: String,
                dnsAddress: String,
            ): Int {
                Log.d(
                    TAG,
                    """
                    onSetInterfaceConfig:
                    [IPv4:$tunnelAddressIPv4]
                    [IPv6:$tunnelAddressIPv6]
                    [dns:$dnsAddress]
                    """.trimIndent(),
                )

                tunnelRepository.setConfig(
                    TunnelConfig(
                        tunnelAddressIPv4,
                        tunnelAddressIPv6,
                        dnsAddress,
                    ),
                )

                // TODO: throw error if failed to establish VpnService
                val fd = buildVpnService().establish()?.detachFd() ?: -1
                protect(fd)
                return fd
            }

            override fun onTunnelReady(): Boolean {
                Log.d(TAG, "onTunnelReady")

                tunnelRepository.setState(Tunnel.State.Up)
                updateStatusNotification("Status: Connected")
                return true
            }

            override fun onAddRoute(
                addr: String,
                prefix: Int,
            ): Int {
                Log.d(TAG, "onAddRoute: $addr/$prefix")
                val route = Cidr(addr, prefix)
                tunnelRepository.addRoute(route)
                val fd = buildVpnService().establish()?.detachFd() ?: -1
                protect(fd)
                return fd
            }

            override fun onRemoveRoute(
                addr: String,
                prefix: Int,
            ): Int {
                Log.d(TAG, "onRemoveRoute: $addr/$prefix")
                val route = Cidr(addr, prefix)
                tunnelRepository.removeRoute(route)
                val fd = buildVpnService().establish()?.detachFd() ?: -1
                protect(fd)
                return fd
            }

            override fun getSystemDefaultResolvers(): Array<ByteArray> {
                return DnsServersDetector(this@TunnelService).servers.map { it.address }.toTypedArray()
            }

            override fun onDisconnect(error: String?): Boolean {
                onSessionDisconnected(
                    error = error?.takeUnless { it == "null" },
                )
                return true
            }
        }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate")
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "onDestroy")
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        Log.d(TAG, "onStartCommand")

        if (intent != null && ACTION_DISCONNECT == intent.action) {
            disconnect()
            return START_NOT_STICKY
        }
        connect()
        return START_STICKY
    }

    private fun onTunnelStateUpdate(state: Tunnel.State) {
        tunnelRepository.setState(state)
    }

    private fun connect() {
        try {
            val config = getConfigUseCase.sync()

            if (tunnelRepository.getState() == Tunnel.State.Up) {
                shouldReconnect = true
                disconnect()
            } else if (config.token != null) {
                onTunnelStateUpdate(Tunnel.State.Connecting)
                updateStatusNotification("Status: Connecting...")

                sessionPtr =
                    TunnelSession.connect(
                        apiUrl = config.apiUrl,
                        token = config.token,
                        deviceId = deviceId(),
                        logDir = getLogDir(),
                        logFilter = config.logFilter,
                        callback = callback,
                    )
            }
        } catch (exception: Exception) {
            Log.e(TAG, "connect(): " + exception.message.toString())
        }
    }

    private fun disconnect() {
        Log.d(TAG, "disconnect(): Attempting to disconnect session")
        try {
            sessionPtr?.let {
                TunnelSession.disconnect(it)
            } ?: onSessionDisconnected(null)
        } catch (exception: Exception) {
            Log.e(TAG, exception.message.toString())
        }
    }

    private fun onSessionDisconnected(error: String?) {
        sessionPtr = null
        onTunnelStateUpdate(Tunnel.State.Down)

        if (shouldReconnect && error == null) {
            shouldReconnect = false
            connect()
        } else {
            tunnelRepository.clearAll()
            preferenceRepository.clearToken()
            onTunnelStateUpdate(Tunnel.State.Closed)
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
    }

    private fun deviceId(): String {
        val deviceId = FirebaseInstallations.getInstance().id
        Log.d(TAG, "Device ID: $deviceId")

        return deviceId.toString()
    }

    private fun getLogDir(): String {
        // Create log directory if it doesn't exist
        val logDir = cacheDir.absolutePath + "/logs"
        Files.createDirectories(Paths.get(logDir))
        return logDir
    }

    private fun configIntent(): PendingIntent? {
        return PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildVpnService(): VpnService.Builder =
        TunnelService().Builder().apply {
            activeTunnel?.let { tunnel ->
                allowFamily(OsConstants.AF_INET)
                allowFamily(OsConstants.AF_INET6)
                setMetered(false); // Inherit the metered status from the underlying networks.
                setUnderlyingNetworks(null); // Use all available networks.

                addAddress(tunnel.config.tunnelAddressIPv4, 32)
                addAddress(tunnel.config.tunnelAddressIPv6, 128)

                addDnsServer(tunnel.config.dnsAddress)

                tunnel.routes.forEach {
                    addRoute(it.address, it.prefix)
                }

                setSession(SESSION_NAME)

                // TODO: Can we do better?
                setMtu(DEFAULT_MTU)
            }
        }

    private fun updateStatusNotification(message: String?) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val chan =
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                NOTIFICATION_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        chan.description = "firezone connection status"

        manager.createNotificationChannel(chan)

        val notificationBuilder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
        val notification =
            notificationBuilder.setOngoing(true)
                .setSmallIcon(R.drawable.ic_firezone_logo)
                .setContentTitle(NOTIFICATION_TITLE)
                .setContentText(message)
                .setPriority(NotificationManager.IMPORTANCE_MIN)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setContentIntent(configIntent())
                .build()

        startForeground(STATUS_NOTIFICATION_ID, notification)
    }

    companion object {
        const val ACTION_CONNECT = "dev.firezone.android.tunnel.CONNECT"
        const val ACTION_DISCONNECT = "dev.firezone.android.tunnel.DISCONNECT"

        private const val NOTIFICATION_CHANNEL_ID = "firezone-connection-status"
        private const val NOTIFICATION_CHANNEL_NAME = "firezone-connection-status"
        private const val STATUS_NOTIFICATION_ID = 1337
        private const val NOTIFICATION_TITLE = "Firezone Connection Status"

        private const val TAG: String = "TunnelService"
        private const val SESSION_NAME: String = "Firezone Connection"
        private const val DEFAULT_MTU: Int = 1280

        @SuppressWarnings("deprecation")
        fun isRunning(context: Context): Boolean {
            val manager = context.getSystemService(ACTIVITY_SERVICE) as ActivityManager
            for (service in manager.getRunningServices(Int.MAX_VALUE)) {
                if (TunnelService::class.java.name == service.service.className) {
                    return true
                }
            }
            return false
        }
    }
}
