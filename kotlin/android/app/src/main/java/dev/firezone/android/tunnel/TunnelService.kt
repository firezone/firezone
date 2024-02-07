/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel

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
import com.google.firebase.crashlytics.ktx.crashlytics
import com.google.firebase.ktx.Firebase
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.tunnel.callback.ConnlibCallback
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.util.DnsServersDetector
import java.lang.IllegalStateException
import java.nio.file.Files
import java.nio.file.Paths
import java.util.UUID
import javax.inject.Inject

@AndroidEntryPoint
@OptIn(ExperimentalStdlibApi::class)
class TunnelService: VpnService() {
    @Inject
    internal lateinit var moshi: Moshi

    @Inject
    internal lateinit var repo: PreferenceRepository

    private var tunnelIpv4Address: String? = null
    private var tunnelIpv6Address: String? = null
    private var tunnelDnsAddresses: List<String> = emptyList()
    private var tunnelRoutes: List<Cidr> = emptyList()
    private var connlibSessionPtr: Long? = null
    private var shouldReconnect: Boolean = false
    var tunnelState = State.DOWN
    var tunnelResources: List<Resource> = emptyList()

    private val callback: ConnlibCallback =
        object : ConnlibCallback {
            override fun onUpdateResources(resourceListJSON: String) {
                Log.d(TAG, "onUpdateResources: $resourceListJSON")
                moshi.adapter<List<Resource>>().fromJson(resourceListJSON)?.let {
                    tunnelResources = it
                }
            }

            override fun onSetInterfaceConfig(
                addressIPv4: String,
                addressIPv6: String,
                dnsAddresses: String,
            ): Int {
                // init tunnel config
                tunnelDnsAddresses = moshi.adapter<List<String>>().fromJson(dnsAddresses)!!
                tunnelIpv4Address = addressIPv4
                tunnelIpv6Address = addressIPv6

                // start VPN
                val fd = buildVpnService().establish()?.detachFd() ?: -1
                protect(fd)
                return fd
            }

            override fun onTunnelReady(): Boolean {
                onTunnelStateUpdate(State.UP)
                updateStatusNotification("Status: Connected")
                return true
            }

            override fun onAddRoute(
                addr: String,
                prefix: Int,
            ): Int {
                Log.d(TAG, "onAddRoute: $addr/$prefix")
                val route = Cidr(addr, prefix)
                tunnelRoutes.toMutableList().add(route)
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
                tunnelRoutes.toMutableList().remove(route)
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


    private fun onSessionDisconnected(error: String?) {
        connlibSessionPtr = null
        onTunnelStateUpdate(State.DOWN)

        if (shouldReconnect && error == null) {
            shouldReconnect = false
            connect()
        } else {
            repo.clearToken()
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
    }

    fun disconnect() {
        Log.d(TAG, "disconnect(): Attempting to disconnect session")
        connlibSessionPtr?.let {
            ConnlibSession.disconnect(it)
        } ?: onSessionDisconnected(null)

        repo.clearToken()
    }

    fun connect() {
        val config = repo.getConfigSync()

        // TODO: Refactor this mess as part of https://github.com/firezone/firezone/issues/3343
        if (tunnelState == State.UP) {
            shouldReconnect = true
            disconnect()
        } else if (config.token != null) {
            onTunnelStateUpdate(State.CONNECTING)
            updateStatusNotification("Status: Connecting...")
            System.loadLibrary("connlib")

            connlibSessionPtr =
                ConnlibSession.connect(
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

    private fun onTunnelStateUpdate(s: State) {
        tunnelState = s
    }
    private fun deviceId(): String {
        // Get the deviceId from the preferenceRepository, or save a new UUIDv4 and return that if it doesn't exist
        val deviceId =
            repo.getDeviceIdSync() ?: run {
                val newDeviceId = UUID.randomUUID().toString()
                repo.saveDeviceIdSync(newDeviceId)
                newDeviceId
            }
        Log.d(TAG, "Device ID: $deviceId")

        return deviceId
    }

    private fun configIntent(): PendingIntent? {
        return PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun getLogDir(): String {
        // Create log directory if it doesn't exist
        val logDir = cacheDir.absolutePath + "/logs"
        Files.createDirectories(Paths.get(logDir))
        return logDir
    }

    private fun buildVpnService(): VpnService.Builder {
        val tunnelService = TunnelService()
        activeTunnel = tunnelService

        return tunnelService.Builder().apply {
            Firebase.crashlytics.log("Building VPN service")
            // Allow traffic to bypass the VPN interface when Always-on VPN is enabled.
            allowBypass()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setMetered(false) // Inherit the metered status from the underlying networks.
            }

            setUnderlyingNetworks(null) // Use all available networks.

            tunnelRoutes.forEach {
                addRoute(it.address, it.prefix)
            }
            tunnelDnsAddresses.forEach { dns ->
                addDnsServer(dns)
            }
            addAddress(tunnelIpv4Address!!, 32)
            addAddress(tunnelIpv6Address!!, 128)

            setSession(SESSION_NAME)
            setMtu(MTU)
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
        enum class State {
            CONNECTING,
            UP,
            DOWN,
            CLOSED,
        }

        const val ACTION_CONNECT = "dev.firezone.android.tunnel.CONNECT"
        const val ACTION_DISCONNECT = "dev.firezone.android.tunnel.DISCONNECT"

        private const val NOTIFICATION_CHANNEL_ID = "firezone-connection-status"
        private const val NOTIFICATION_CHANNEL_NAME = "firezone-connection-status"
        private const val STATUS_NOTIFICATION_ID = 1337
        private const val NOTIFICATION_TITLE = "Firezone Connection Status"

        private const val TAG: String = "TunnelService"
        private const val SESSION_NAME: String = "Firezone Connection"
        private const val MTU: Int = 1280

        var activeTunnel: TunnelService? = null

        fun start(context: Context) {
            if (activeTunnel != null) {
                throw IllegalStateException("TunnelService already running")
            }

            // Start system VPN service
            val intent = Intent(context, TunnelService::class.java)
            intent.action = ACTION_CONNECT
            context.startService(intent)

            activeTunnel = TunnelService()
            activeTunnel!!.connect()
        }

        // Starts the TunnelService given a context
        // For user-initiated sessions, this is started from the UI
        fun stop(context: Context) {
            if (activeTunnel == null) {
                throw IllegalStateException("TunnelService not running")
            }

            val intent = Intent(context, TunnelService::class.java)
            intent.action = ACTION_DISCONNECT
            context.startService(intent)

            activeTunnel!!.disconnect()
            activeTunnel = null
        }
    }
}
