package dev.firezone.android.tunnel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.system.OsConstants
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.installations.FirebaseInstallations
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.BuildConfig
import dev.firezone.android.R
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.tunnel.callback.ConnlibCallback
import dev.firezone.android.tunnel.data.TunnelRepository
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.Tunnel
import dev.firezone.android.tunnel.model.TunnelConfig
import java.nio.file.Files
import java.nio.file.Paths
import javax.inject.Inject

@AndroidEntryPoint
@OptIn(ExperimentalStdlibApi::class)
class TunnelService: VpnService() {

    @Inject
    internal lateinit var getConfigUseCase: GetConfigUseCase

    @Inject
    internal lateinit var tunnelRepository: TunnelRepository

    @Inject
    internal lateinit var moshi: Moshi

    private var sessionPtr: Long? = null

    private val activeTunnel: Tunnel?
        get() = tunnelRepository.get()

    private val callback: ConnlibCallback = object: ConnlibCallback {
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
            dnsFallbackStrategy: String
        ): Int {
            Log.d(TAG, "onSetInterfaceConfig: [IPv4:$tunnelAddressIPv4] [IPv6:$tunnelAddressIPv6] [dns:$dnsAddress] [dnsFallbackStrategy:$dnsFallbackStrategy]")

            tunnelRepository.setConfig(
                TunnelConfig(
                    tunnelAddressIPv4, tunnelAddressIPv6, dnsAddress, dnsFallbackStrategy
                )
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

        override fun onError(error: String): Boolean {
            Log.d(TAG, "onError: $error")
            return true
        }

        override fun onAddRoute(cidrAddress: String) {
            Log.d(TAG, "onAddRoute: $cidrAddress")

            tunnelRepository.addRoute(cidrAddress)
        }

        override fun onRemoveRoute(cidrAddress: String) {
            Log.d(TAG, "onRemoveRoute: $cidrAddress")

            tunnelRepository.removeRoute(cidrAddress)
        }

        override fun onDisconnect(error: String?): Boolean {
            Log.d(TAG, "onDisconnect $error")

            onTunnelStateUpdate(Tunnel.State.Down)
            return true
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.d("FirezoneVpnService", "onCreate")
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d("FirezoneVpnService", "onDestroy")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d("FirezoneVpnService", "onStartCommand")

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

            Log.d("Connlib", "accountId: ${config.accountId}")
            Log.d("Connlib", "token: ${config.token}")

            if (config.accountId != null && config.token != null) {
                Log.d("Connlib", "Attempting to establish TunnelSession...")
                sessionPtr = TunnelSession.connect(
                    controlPlaneUrl = BuildConfig.CONTROL_PLANE_URL,
                    token = config.token,
                    deviceId = deviceId(),
                    logDir = getLogDir(),
                    callback = callback
                )
                Log.d("Connlib", "connlib session started! sessionPtr: $sessionPtr")

                onTunnelStateUpdate(Tunnel.State.Connecting)

                updateStatusNotification("Status: Connecting...")
            }
        } catch (exception: Exception) {
            Log.e("Connection error:", exception.message.toString())
        }
    }

    private fun disconnect() {
        try {
            sessionPtr?.let {
                TunnelSession.disconnect(it)
            }
            tunnelRepository.setState(Tunnel.State.Down)
        } catch (exception: Exception) {
            Log.e("Disconnection error:", exception.message.toString())
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun deviceId(): String {
        val deviceId = FirebaseInstallations.getInstance().id

        Log.d("Connlib", "Device ID: $deviceId")

        return deviceId.toString()
    }

    private fun getLogDir(): String {
        // Create log directory if it doesn't exist
        val logDir = cacheDir.absolutePath + "/log"
        Files.createDirectories(Paths.get(logDir))
        return logDir
    }

    private fun configIntent(): PendingIntent? {
        return PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun buildVpnService(): VpnService.Builder =
        TunnelService().Builder().apply {
            activeTunnel?.let { tunnel ->
                allowFamily(OsConstants.AF_INET)
                allowFamily(OsConstants.AF_INET6);
                setMetered(false); // Inherit the metered status from the underlying networks.
                setUnderlyingNetworks(null); // Use all available networks.

                addAddress(tunnel.config.tunnelAddressIPv4, 32)
                addAddress(tunnel.config.tunnelAddressIPv6, 128)

                addDnsServer(tunnel.config.dnsAddress)

                /*tunnel.routes.forEach {
                    addRoute(it, 32)
                }*/

                // TODO: These are the staging Resources. Remove these in favor of the onUpdateResources callback.
                addRoute("100.100.111.1", 32)
                addRoute("172.31.82.179", 32)
                addRoute("172.31.83.10", 32)
                addRoute("172.31.92.238", 32)
                addRoute("172.31.93.123", 32)

                setSession(SESSION_NAME)

                // TODO: Can we do better?
                setMtu(DEFAULT_MTU)
            }
        }

    private fun updateStatusNotification(message: String?) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val chan = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            NOTIFICATION_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_DEFAULT
        )
        chan.description = "firezone vpn status"

        manager.createNotificationChannel(chan)

        val notificationBuilder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
        val notification = notificationBuilder.setOngoing(true)
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

        private const val NOTIFICATION_CHANNEL_ID = "firezone-vpn-status"
        private const val NOTIFICATION_CHANNEL_NAME = "firezone-vpn-status"
        private const val STATUS_NOTIFICATION_ID = 1337
        private const val NOTIFICATION_TITLE = "Firezone Vpn Status"

        private const val TAG: String = "TunnelManager"
        private const val SESSION_NAME: String = "Firezone VPN"
        private const val DEFAULT_MTU: Int = 1280
    }
}
