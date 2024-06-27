/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.tunnel

import NetworkMonitor
import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import androidx.lifecycle.MutableLiveData
import com.google.firebase.crashlytics.ktx.crashlytics
import com.google.firebase.ktx.Firebase
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.Repository
import dev.firezone.android.tunnel.callback.ConnlibCallback
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
import java.nio.file.Files
import java.nio.file.Paths
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import javax.inject.Inject

@AndroidEntryPoint
@OptIn(ExperimentalStdlibApi::class)
class TunnelService : VpnService() {
    @Inject
    internal lateinit var repo: Repository

    @Inject
    internal lateinit var appRestrictions: Bundle

    @Inject
    internal lateinit var moshi: Moshi

    private var tunnelIpv4Address: String? = null
    private var tunnelIpv6Address: String? = null
    private var tunnelDnsAddresses: MutableList<String> = mutableListOf()
    private var tunnelRoutes: MutableList<Cidr> = mutableListOf()
    private var _tunnelResources: List<Resource> = emptyList()
    private var _tunnelState: State = State.DOWN
    private var networkCallback: NetworkMonitor? = null

    // General purpose mutex lock for preventing network monitoring from calling connlib
    // during shutdown.
    val lock = ReentrantLock()

    var startedByUser: Boolean = false
    var connlibSessionPtr: Long? = null

    var tunnelResources: List<Resource>
        get() = _tunnelResources
        set(value) {
            _tunnelResources = value
            updateResourcesLiveData(value)
        }
    var tunnelState: State
        get() = _tunnelState
        set(value) {
            _tunnelState = value
            updateServiceStateLiveData(value)
        }

    // Used to update the UI when the SessionActivity is bound to this service
    private var serviceStateLiveData: MutableLiveData<State>? = null
    private var resourcesLiveData: MutableLiveData<List<Resource>>? = null

    // For binding the SessionActivity view to this service
    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): TunnelService = this@TunnelService
    }

    override fun onBind(intent: Intent): IBinder {
        return binder
    }

    private val callback: ConnlibCallback =
        object : ConnlibCallback {
            override fun onUpdateResources(resourceListJSON: String) {
                Log.d(TAG, "onUpdateResources: $resourceListJSON")
                Firebase.crashlytics.log("onUpdateResources: $resourceListJSON")
                moshi.adapter<List<Resource>>().fromJson(resourceListJSON)?.let {
                    tunnelResources = it
                }
            }

            override fun onSetInterfaceConfig(
                addressIPv4: String,
                addressIPv6: String,
                dnsAddresses: String,
            ): Int {
                Log.d(TAG, "onSetInterfaceConfig: $addressIPv4, $addressIPv6, $dnsAddresses")
                Firebase.crashlytics.log("onSetInterfaceConfig: $addressIPv4, $addressIPv6, $dnsAddresses")

                // init tunnel config
                tunnelDnsAddresses = moshi.adapter<MutableList<String>>().fromJson(dnsAddresses)!!
                tunnelIpv4Address = addressIPv4
                tunnelIpv6Address = addressIPv6

                // start VPN
                return buildVpnService()
            }

            override fun onUpdateRoutes(
                routes4JSON: String,
                routes6JSON: String,
            ): Int {
                Log.d(TAG, "onUpdateRoutes: $routes4JSON, $routes6JSON")
                Firebase.crashlytics.log("onUpdateRoutes: $routes4JSON, $routes6JSON")
                val routes4 = moshi.adapter<MutableList<Cidr>>().fromJson(routes4JSON)!!
                val routes6 = moshi.adapter<MutableList<Cidr>>().fromJson(routes6JSON)!!

                tunnelRoutes.clear()
                tunnelRoutes.addAll(routes4)
                tunnelRoutes.addAll(routes6)

                return buildVpnService()
            }

            // Unexpected disconnect, most likely a 401. Clear the token and initiate a stop of the
            // service.
            override fun onDisconnect(error: String): Boolean {
                Log.d(TAG, "onDisconnect: $error")
                Firebase.crashlytics.log("onDisconnect: $error")

                stopNetworkMonitoring()

                // Clear any user tokens and actorNames
                repo.clearToken()
                repo.clearActorName()

                shutdown()
                if (startedByUser) {
                    updateStatusNotification(TunnelStatusNotification.SignedOut)
                }
                return true
            }

            override fun protectFileDescriptor(fileDescriptor: Int) {
                protect(fileDescriptor)
            }
        }

    private val restrictionsFilter = IntentFilter(Intent.ACTION_APPLICATION_RESTRICTIONS_CHANGED)

    private val restrictionsReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                Log.d(TAG, "onReceive")
                val restrictionsManager = context.getSystemService(Context.RESTRICTIONS_SERVICE) as android.content.RestrictionsManager
                val newAppRestrictions = restrictionsManager.applicationRestrictions
                val changed = MANAGED_CONFIGURATIONS.any { newAppRestrictions.getString(it) != appRestrictions.getString(it) }
                if (!changed) {
                    return
                }

                if (connlibSessionPtr != null) {
                    disconnect()
                }
                appRestrictions = newAppRestrictions
                connect()
            }
        }

    // Primary callback used to start and stop the VPN service
    // This can be called either from the UI or from the system
    // via AlwaysOnVpn.
    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        Log.d(TAG, "onStartCommand")
        if (intent?.getBooleanExtra("startedByUser", false) == true) {
            startedByUser = true
        }
        connect()
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate")
        registerReceiver(restrictionsReceiver, restrictionsFilter)
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        unregisterReceiver(restrictionsReceiver)
        super.onDestroy()
    }

    override fun onRevoke() {
        Log.d(TAG, "onRevoke")
        disconnect()
        super.onRevoke()
    }

    // Call this to stop the tunnel and shutdown the service, leaving the token intact.
    fun disconnect() {
        Log.d(TAG, "disconnect")

        // Acquire mutex lock
        lock.lock()

        stopNetworkMonitoring()

        connlibSessionPtr?.let {
            ConnlibSession.disconnect(it)
        }

        shutdown()

        // Release mutex lock
        lock.unlock()
    }

    private fun shutdown() {
        Log.d(TAG, "shutdown")

        connlibSessionPtr = null
        stopSelf()
        tunnelState = State.DOWN
    }

    private fun connect() {
        val token = appRestrictions.getString("token") ?: repo.getTokenSync()
        val config = repo.getConfigSync()

        if (!token.isNullOrBlank()) {
            tunnelState = State.CONNECTING
            updateStatusNotification(TunnelStatusNotification.Connecting)
            System.loadLibrary("connlib")

            connlibSessionPtr =
                ConnlibSession.connect(
                    apiUrl = config.apiUrl,
                    token = token,
                    deviceId = deviceId(),
                    deviceName = getDeviceName(),
                    osVersion = Build.VERSION.RELEASE,
                    logDir = getLogDir(),
                    logFilter = config.logFilter,
                    callback = callback,
                )

            startNetworkMonitoring()
        }
    }

    private fun startNetworkMonitoring() {
        networkCallback = NetworkMonitor(this)

        val networkRequest =
            NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
        val connectivityManager =
            getSystemService(ConnectivityManager::class.java) as ConnectivityManager
        connectivityManager.requestNetwork(networkRequest, networkCallback!!)
    }

    private fun stopNetworkMonitoring() {
        networkCallback?.let {
            val connectivityManager =
                getSystemService(ConnectivityManager::class.java) as ConnectivityManager
            connectivityManager.unregisterNetworkCallback(it)

            networkCallback = null
        }
    }

    fun setServiceStateLiveData(liveData: MutableLiveData<State>) {
        serviceStateLiveData = liveData

        // Update the newly bound SessionActivity with our current state
        serviceStateLiveData?.postValue(tunnelState)
    }

    fun setResourcesLiveData(liveData: MutableLiveData<List<Resource>>) {
        resourcesLiveData = liveData

        // Update the newly bound SessionActivity with our current resources
        resourcesLiveData?.postValue(tunnelResources)
    }

    private fun updateServiceStateLiveData(state: State) {
        serviceStateLiveData?.postValue(state)
    }

    private fun updateResourcesLiveData(resources: List<Resource>) {
        resourcesLiveData?.postValue(resources)
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

    private fun getLogDir(): String {
        // Create log directory if it doesn't exist
        val logDir = cacheDir.absolutePath + "/logs"
        Files.createDirectories(Paths.get(logDir))
        return logDir
    }

    private fun buildVpnService(): Int {
        Builder().apply {
            Firebase.crashlytics.log("Building VPN service")
            // Allow traffic to bypass the VPN interface when Always-on VPN is enabled.
            allowBypass()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Firebase.crashlytics.log("Setting transport info")
                setMetered(false) // Inherit the metered status from the underlying networks.
            }

            Firebase.crashlytics.log("Setting underlying networks")
            setUnderlyingNetworks(null) // Use all available networks.

            Log.d(TAG, "Routes: $tunnelRoutes")
            Firebase.crashlytics.log("Routes: $tunnelRoutes")
            tunnelRoutes.forEach {
                addRoute(it.address, it.prefix)
            }

            Log.d(TAG, "DNS Servers: $tunnelDnsAddresses")
            Firebase.crashlytics.log("DNS Servers: $tunnelDnsAddresses")
            tunnelDnsAddresses.forEach { dns ->
                addDnsServer(dns)
            }

            Log.d(TAG, "IPv4 Address: $tunnelIpv4Address")
            Firebase.crashlytics.log("IPv4 Address: $tunnelIpv4Address")
            addAddress(tunnelIpv4Address!!, 32)

            Log.d(TAG, "IPv6 Address: $tunnelIpv6Address")
            Firebase.crashlytics.log("IPv6 Address: $tunnelIpv6Address")
            addAddress(tunnelIpv6Address!!, 128)

            updateAllowedDisallowedApplications("allowedApplications", ::addAllowedApplication)
            updateAllowedDisallowedApplications(
                "disallowedApplications",
                ::addDisallowedApplication,
            )

            setSession(SESSION_NAME)
            setMtu(MTU)
        }.establish()!!.let {
            return it.detachFd()
        }
    }

    private fun updateAllowedDisallowedApplications(
        key: String,
        allowOrDisallow: (String) -> Unit,
    ) {
        val applications = appRestrictions.getString(key)
        Log.d(TAG, "$key: $applications")
        Firebase.crashlytics.log("$key: $applications")
        applications?.let {
            if (it.isNotBlank()) {
                it.split(",").forEach { p ->
                    if (p.isNotBlank()) {
                        allowOrDisallow(p.trim())
                    }
                }
            }
        }
    }

    fun updateStatusNotification(statusType: TunnelStatusNotification.StatusType) {
        val notification = TunnelStatusNotification.update(this, statusType).build()
        startForeground(TunnelStatusNotification.ID, notification)
    }

    private fun getDeviceName(): String {
        val deviceName = appRestrictions.getString("deviceName")
        return if (deviceName.isNullOrBlank() || deviceName == "null") {
            Build.MODEL
        } else {
            deviceName
        }
    }

    companion object {
        enum class State {
            CONNECTING,
            UP,
            DOWN,
        }

        private const val TAG: String = "TunnelService"
        private const val SESSION_NAME: String = "Firezone Connection"
        private const val MTU: Int = 1280

        private val MANAGED_CONFIGURATIONS = arrayOf("token", "allowedApplications", "disallowedApplications", "deviceName")

        // FIXME: Find another way to check if we're running
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

        fun start(context: Context) {
            Log.d(TAG, "Starting TunnelService")
            val intent = Intent(context, TunnelService::class.java)
            intent.putExtra("startedByUser", true)
            context.startService(intent)
        }
    }
}
