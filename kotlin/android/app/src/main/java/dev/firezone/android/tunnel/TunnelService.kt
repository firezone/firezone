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
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.google.firebase.crashlytics.ktx.crashlytics
import com.google.firebase.ktx.Firebase
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.tunnel.callback.ConnlibCallback
import dev.firezone.android.tunnel.data.TunnelRepository
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.TunnelState
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.util.DnsServersDetector
import java.nio.file.Files
import java.nio.file.Paths
import java.util.UUID
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
                dnsAddresses: String,
            ): Int {
                Log.d(
                    TAG,
                    """
                    onSetInterfaceConfig:
                    [IPv4:$tunnelAddressIPv4]
                    [IPv6:$tunnelAddressIPv6]
                    [dns:$dnsAddresses]
                    """.trimIndent(),
                )
                Firebase.crashlytics.log(
                    """
                    onSetInterfaceConfig:
                    [IPv4:$tunnelAddressIPv4]
                    [IPv6:$tunnelAddressIPv6]
                    [dns:$dnsAddresses]
                    """.trimIndent(),
                )

                val dns = moshi.adapter<List<String>>().fromJson(dnsAddresses) ?: emptyList()

                tunnelRepository.setIPv4Address(tunnelAddressIPv4)
                tunnelRepository.setIPv6Address(tunnelAddressIPv6)
                tunnelRepository.setDnsAddresses(dns)
                tunnelRepository.setRoutes(emptyList())
                tunnelRepository.setResources(emptyList())

                val fd = try {
                    buildVpnService().establish()?.detachFd() ?: -1
                } catch (e: Exception) {
                    Firebase.crashlytics.recordException(e)
                    -1
                }

                protect(fd)
                return fd
            }

            override fun onTunnelReady(): Boolean {
                Log.d(TAG, "onTunnelReady")

                tunnelRepository.setState(TunnelState.Up)
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
                return DnsServersDetector(this@TunnelService).servers.map { it.address }
                    .toTypedArray()
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

    private fun onTunnelStateUpdate(state: TunnelState) {
        tunnelRepository.setState(state)
    }

    private fun connect() {
        val config = getConfigUseCase.sync()

        if (tunnelRepository.getState() == TunnelState.Up) {
            shouldReconnect = true
            disconnect()
        } else if (config.token != null) {
            onTunnelStateUpdate(TunnelState.Connecting)
            updateStatusNotification("Status: Connecting...")
            System.loadLibrary("connlib")

            sessionPtr =
                TunnelSession.connect(
                    apiUrl = config.apiUrl,
                    token = config.token,
                    deviceId = deviceId(),
                    deviceName = Build.MODEL,
                    osVersion = Build.VERSION.RELEASE,
                    logDir = getLogDir(),
                    logFilter = config.logFilter,
                    callback = callback,
                )
        }
    }

    private fun disconnect() {
        Log.d(TAG, "disconnect(): Attempting to disconnect session")
        sessionPtr?.let {
            TunnelSession.disconnect(it)
        } ?: onSessionDisconnected(null)
    }

    private fun onSessionDisconnected(error: String?) {
        sessionPtr = null
        onTunnelStateUpdate(TunnelState.Down)

        if (shouldReconnect && error == null) {
            shouldReconnect = false
            connect()
        } else {
            tunnelRepository.clearAll()
            preferenceRepository.clearToken()
            onTunnelStateUpdate(TunnelState.Closed)
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
    }

    private fun deviceId(): String {
        // Get the deviceId from the preferenceRepository, or save a new UUIDv4 and return that if it doesn't exist
        val deviceId =
            preferenceRepository.getDeviceIdSync() ?: run {
                val newDeviceId = UUID.randomUUID().toString()
                preferenceRepository.saveDeviceIdSync(newDeviceId)
                newDeviceId
            }
        Log.d(TAG, "Device ID: $deviceId")

        return deviceId
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
            Firebase.crashlytics.log("Building VPN service")
            // Allow traffic to bypass the VPN interface when Always-on VPN is enabled.
            allowBypass()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setMetered(false) // Inherit the metered status from the underlying networks.
            }

            setUnderlyingNetworks(null) // Use all available networks.

            Firebase.crashlytics.log("Adding routes: ${tunnelRepository.getRoutes()}")
            tunnelRepository.getRoutes()?.forEach {
                Log.d(TAG, "Adding route: $it")
                addRoute(it.address, it.prefix)
            }

            Firebase.crashlytics.log("Adding DNS servers: ${tunnelRepository.getDnsAddresses()}")
            tunnelRepository.getDnsAddresses()?.forEach { dns ->
                Log.d(TAG, "Adding DNS server: $dns")
                addDnsServer(dns)
            }

            Firebase.crashlytics.log("Adding IPv4: ${tunnelRepository.getIPv4Address()}")
            addAddress(tunnelRepository.getIPv4Address()!!, 32)

            Firebase.crashlytics.log("Adding IPv6: ${tunnelRepository.getIPv6Address()}")
            addAddress(tunnelRepository.getIPv6Address()!!, 128)

            setSession(SESSION_NAME)
            setMtu(DEFAULT_MTU)
        }

    private fun updateStatusNotification(message: String?) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val chan =
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                NOTIFICATION_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        chan.description = "Firezone connection status"

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
