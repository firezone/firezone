/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.tunnel

import DisconnectMonitor
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
import com.google.android.gms.tasks.Tasks
import com.google.firebase.installations.FirebaseInstallations
import com.google.gson.FieldNamingPolicy
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.isEnabled
import dev.firezone.android.tunnel.callback.ConnlibCallback
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.isInternetResource
import java.nio.file.Files
import java.nio.file.Paths
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantLock
import javax.inject.Inject

data class DeviceInfo(
    var firebaseInstallationId: String? = null,
)

@AndroidEntryPoint
@OptIn(ExperimentalStdlibApi::class)
class TunnelService : VpnService() {
    @Inject
    internal lateinit var repo: Repository

    @Inject
    internal lateinit var appRestrictions: Bundle

    @Inject
    internal lateinit var moshi: Moshi

    var tunnelIpv4Address: String? = null
    var tunnelIpv6Address: String? = null
    private var tunnelDnsAddresses: MutableList<String> = mutableListOf()
    private var tunnelSearchDomain: String? = null
    private var tunnelRoutes: MutableList<Cidr> = mutableListOf()
    private var _tunnelResources: List<Resource> = emptyList()
    private var _tunnelState: State = State.DOWN
    private var resourceState: ResourceState = ResourceState.UNSET

    // For reacting to changes to the network
    private var networkCallback: NetworkMonitor? = null

    // For reacting to disconnects of our VPN service, for example when the user disconnects
    // the VPN from the system settings or MDM disconnects us.
    private var disconnectCallback: DisconnectMonitor? = null

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

    override fun onBind(intent: Intent): IBinder = binder

    private val callback: ConnlibCallback =
        object : ConnlibCallback {
            override fun onUpdateResources(resourceListJSON: String) {
                moshi.adapter<List<Resource>>().fromJson(resourceListJSON)?.let {
                    tunnelResources = it
                    resourcesUpdated()
                }
            }

            override fun onSetInterfaceConfig(
                addressIPv4: String,
                addressIPv6: String,
                dnsAddresses: String,
                searchDomain: String?,
                routes4JSON: String,
                routes6JSON: String,
            ) {
                // init tunnel userConfig
                tunnelDnsAddresses = moshi.adapter<MutableList<String>>().fromJson(dnsAddresses)!!
                val routes4 = moshi.adapter<MutableList<Cidr>>().fromJson(routes4JSON)!!
                val routes6 = moshi.adapter<MutableList<Cidr>>().fromJson(routes6JSON)!!

                tunnelSearchDomain = searchDomain
                tunnelIpv4Address = addressIPv4
                tunnelIpv6Address = addressIPv6
                tunnelRoutes.clear()
                tunnelRoutes.addAll(routes4)
                tunnelRoutes.addAll(routes6)

                buildVpnService()
            }

            // Unexpected disconnect, most likely a 401. Clear the token and initiate a stop of the
            // service.
            override fun onDisconnect(error: String): Boolean {
                stopNetworkMonitoring()
                stopDisconnectMonitoring()

                // Clear any user tokens and actorNames
                repo.clearToken()
                repo.clearActorName()

                // Free the connlib session
                connlibSessionPtr?.let {
                    ConnlibSession.disconnect(it)
                }

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

    private fun buildVpnService() {
        fun handleApplications(
            appRestrictions: Bundle,
            key: String,
            action: (String) -> Unit,
        ) {
            appRestrictions.getString(key)?.takeIf { it.isNotBlank() }?.split(",")?.forEach { p ->
                p.trim().takeIf { it.isNotBlank() }?.let(action)
            }
        }

        Builder()
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    setMetered(false) // Inherit the metered status from the underlying networks.
                }

                if (tunnelRoutes.all { it.prefix != 0 }) {
                    // Allow traffic to bypass the VPN interface when Always-on VPN is enabled only
                    // if full-route is not enabled.
                    allowBypass()
                }

                setUnderlyingNetworks(null) // Use all available networks.

                setSession(SESSION_NAME)
                setMtu(MTU)

                handleApplications(appRestrictions, "allowedApplications") { addAllowedApplication(it) }
                handleApplications(
                    appRestrictions,
                    "disallowedApplications",
                ) { addDisallowedApplication(it) }

                // Never route GCM notifications through the tunnel.
                addDisallowedApplication("com.google.android.gms") // Google Mobile Services
                addDisallowedApplication("com.google.firebase.messaging") // Firebase Cloud Messaging
                addDisallowedApplication("com.google.android.gsf") // Google Services Framework

                tunnelRoutes.forEach {
                    addRoute(it.address, it.prefix)
                }

                tunnelDnsAddresses.forEach { dns ->
                    addDnsServer(dns)
                }

                tunnelSearchDomain?.let {
                    addSearchDomain(it)
                }

                addAddress(tunnelIpv4Address!!, 32)
                addAddress(tunnelIpv6Address!!, 128)
            }.establish()
            ?.detachFd()
            ?.also { fd ->
                connlibSessionPtr?.let {
                    ConnlibSession.setTun(it, fd)
                }
            }
    }

    private val restrictionsFilter = IntentFilter(Intent.ACTION_APPLICATION_RESTRICTIONS_CHANGED)

    private val restrictionsReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                // Only change VPN if appRestrictions have changed
                val restrictionsManager = context.getSystemService(Context.RESTRICTIONS_SERVICE) as android.content.RestrictionsManager
                val newAppRestrictions = restrictionsManager.applicationRestrictions
                val changed = MANAGED_CONFIGURATIONS.any { newAppRestrictions.getString(it) != appRestrictions.getString(it) }
                if (!changed) {
                    return
                }
                appRestrictions = newAppRestrictions

                buildVpnService()
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
        if (intent?.getBooleanExtra("startedByUser", false) == true) {
            startedByUser = true
        }
        connect()
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        registerReceiver(restrictionsReceiver, restrictionsFilter)
    }

    override fun onDestroy() {
        unregisterReceiver(restrictionsReceiver)
        super.onDestroy()
    }

    override fun onRevoke() {
        disconnect()
        super.onRevoke()
    }

    fun internetState(): ResourceState = resourceState

    private fun internetResource(): Resource? = tunnelResources.firstOrNull { it.isInternetResource() }

    // UI updates for resources
    fun resourcesUpdated() {
        val currentlyDisabled =
            if (internetResource() != null && !resourceState.isEnabled()) {
                setOf(internetResource()!!.id)
            } else {
                emptySet()
            }

        connlibSessionPtr?.let {
            ConnlibSession.setDisabledResources(it, Gson().toJson(currentlyDisabled))
        }
    }

    fun internetResourceToggled(state: ResourceState) {
        resourceState = state

        repo.saveInternetResourceStateSync(resourceState)

        resourcesUpdated()
    }

    // Call this to stop the tunnel and shutdown the service, leaving the token intact.
    fun disconnect() {
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
        connlibSessionPtr = null
        stopSelf()
        tunnelState = State.DOWN
    }

    private fun connect() {
        val token = appRestrictions.getString("token") ?: repo.getTokenSync()
        val config = repo.getConfigSync()
        resourceState = repo.getInternetResourceStateSync()

        if (!token.isNullOrBlank()) {
            tunnelState = State.CONNECTING
            updateStatusNotification(TunnelStatusNotification.Connecting)

            val executor = Executors.newSingleThreadExecutor()

            executor.execute {
                val deviceInfo = DeviceInfo()

                runCatching {
                    Tasks.await(FirebaseInstallations.getInstance().id)
                }.onSuccess { firebaseInstallationId ->
                    deviceInfo.firebaseInstallationId = firebaseInstallationId
                }.onFailure { exception ->
                    Log.d(TAG, "Failed to obtain firebase installation id: $exception")
                }

                val gson: Gson =
                    GsonBuilder()
                        .setFieldNamingPolicy(FieldNamingPolicy.LOWER_CASE_WITH_UNDERSCORES)
                        .create()

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
                        deviceInfo = gson.toJson(deviceInfo),
                    )

                startNetworkMonitoring()
                startDisconnectMonitoring()
            }
        }
    }

    private fun startDisconnectMonitoring() {
        disconnectCallback = DisconnectMonitor(this)
        val networkRequest = NetworkRequest.Builder()
        val connectivityManager =
            getSystemService(ConnectivityManager::class.java) as ConnectivityManager
        // Listens for changes for *all* networks
        connectivityManager.requestNetwork(
            networkRequest.removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),
            disconnectCallback!!,
        )
    }

    private fun startNetworkMonitoring() {
        networkCallback = NetworkMonitor(this)
        val networkRequest = NetworkRequest.Builder()
        val connectivityManager =
            getSystemService(ConnectivityManager::class.java) as ConnectivityManager
        // Listens for changes *not* including VPN networks
        connectivityManager.requestNetwork(
            networkRequest.addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),
            networkCallback!!,
        )
    }

    private fun stopNetworkMonitoring() {
        networkCallback?.let {
            val connectivityManager =
                getSystemService(ConnectivityManager::class.java) as ConnectivityManager
            connectivityManager.unregisterNetworkCallback(it)

            networkCallback = null
        }
    }

    private fun stopDisconnectMonitoring() {
        disconnectCallback?.let {
            val connectivityManager =
                getSystemService(ConnectivityManager::class.java) as ConnectivityManager
            connectivityManager.unregisterNetworkCallback(it)

            disconnectCallback = null
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
                val newDeviceId =
                    java.util.UUID
                        .randomUUID()
                        .toString()
                repo.saveDeviceIdSync(newDeviceId)
                newDeviceId
            }

        return deviceId
    }

    private fun getLogDir(): String {
        // Create log directory if it doesn't exist
        val logDir = cacheDir.absolutePath + "/logs"
        Files.createDirectories(Paths.get(logDir))
        return logDir
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

        private const val SESSION_NAME: String = "Firezone Connection"
        private const val MTU: Int = 1280
        private const val TAG: String = "TunnelService"

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
            val intent = Intent(context, TunnelService::class.java)
            intent.putExtra("startedByUser", true)
            context.startService(intent)
        }
    }
}
