// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
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
import com.google.android.gms.tasks.Tasks
import com.google.firebase.installations.FirebaseInstallations
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.isEnabled
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.Site
import dev.firezone.android.tunnel.model.StatusEnum
import dev.firezone.android.tunnel.model.isInternetResource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.channels.produce
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import uniffi.connlib.ConnlibException
import uniffi.connlib.DeviceInfo
import uniffi.connlib.Event
import uniffi.connlib.ProtectSocket
import uniffi.connlib.Session
import uniffi.connlib.SessionInterface
import uniffi.connlib.use
import java.nio.file.Files
import java.nio.file.Paths
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

    var tunnelIpv4Address: String? = null
    var tunnelIpv6Address: String? = null
    private var tunnelDnsAddresses: MutableList<String> = mutableListOf()
    private var tunnelSearchDomain: String? = null
    private var tunnelRoutes: MutableList<Cidr> = mutableListOf()
    private var _tunnelResources: List<Resource> = emptyList()
    private var _tunnelState: State = State.DOWN
    private var resourceState: ResourceState = ResourceState.UNSET
    private val unreachableSites: MutableSet<String> = mutableSetOf()

    // For reacting to changes to the network
    private var networkCallback: NetworkMonitor? = null

    // For reacting to disconnects of our VPN service, for example when the user disconnects
    // the VPN from the system settings or MDM disconnects us.
    private var disconnectCallback: DisconnectMonitor? = null

    var startedByUser: Boolean = false
    private var commandChannel: Channel<TunnelCommand>? = null
    private val serviceScope = CoroutineScope(SupervisorJob())

    var tunnelResources: List<Resource>
        get() = _tunnelResources
        set(value) {
            _tunnelResources = value
            updateResourcesStateFlow(value)
        }
    var tunnelState: State
        get() = _tunnelState
        set(value) {
            _tunnelState = value
            updateServiceStateFlow(value)
        }

    // Used to update the UI when the SessionActivity is bound to this service
    private var serviceStateMutableStateFlow: MutableStateFlow<State?>? = null
    private var resourcesMutableStateFlow: MutableStateFlow<List<Resource>>? = null

    // For binding the SessionActivity view to this service
    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): TunnelService = this@TunnelService
    }

    override fun onBind(intent: Intent): IBinder = binder

    private val protectSocket: ProtectSocket =
        object : ProtectSocket {
            override fun protectSocket(fd: Int) {
                protect(fd)
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
            ?.also { fd -> sendTunnelCommand(TunnelCommand.SetTun(fd)) }
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
                serviceScope.launch { repo.saveManagedConfiguration(newAppRestrictions).collect {} }
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
        serviceScope.cancel()
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
        sendTunnelCommand(
            TunnelCommand.SetInternetResourceState(resourceState.isEnabled()),
        )
    }

    fun internetResourceToggled(state: ResourceState) {
        resourceState = state

        repo.saveInternetResourceStateSync(resourceState)

        resourcesUpdated()
    }

    // Call this to stop the tunnel and shutdown the service, leaving the token intact.
    fun disconnect() {
        sendTunnelCommand(TunnelCommand.Disconnect)
    }

    fun setDns(dnsList: List<String>) {
        sendTunnelCommand(TunnelCommand.SetDns(dnsList))
    }

    fun reset() {
        sendTunnelCommand(TunnelCommand.Reset)
    }

    private fun connect() {
        val token = appRestrictions.getString("token") ?: repo.getTokenSync()
        val config = repo.getConfigSync()
        resourceState = repo.getInternetResourceStateSync()

        if (!token.isNullOrBlank()) {
            tunnelState = State.CONNECTING
            // Dismiss any previous disconnected notifications
            TunnelNotification.dismissDisconnectedNotification(this)

            val firebaseInstallationId =
                runCatching { Tasks.await(FirebaseInstallations.getInstance().id) }
                    .getOrElse { exception ->
                        Log.d(TAG, "Failed to obtain firebase installation id: $exception")
                        null
                    }

            val deviceInfo =
                DeviceInfo(
                    firebaseInstallationId = firebaseInstallationId,
                    deviceUuid = null,
                    deviceSerial = null,
                    identifierForVendor = null,
                )

            commandChannel = Channel<TunnelCommand>(Channel.UNLIMITED)

            val context = this

            serviceScope.launch {
                try {
                    Session
                        .newAndroid(
                            apiUrl = config.apiUrl,
                            token = token,
                            accountSlug = config.accountSlug,
                            deviceId = deviceId(),
                            deviceName = getDeviceName(),
                            logDir = getLogDir(),
                            logFilter = config.logFilter,
                            isInternetResourceActive = resourceState.isEnabled(),
                            protectSocket = protectSocket,
                            deviceInfo = deviceInfo,
                        ).use { session ->
                            startNetworkMonitoring()
                            startDisconnectMonitoring()

                            eventLoop(session, commandChannel!!)

                            Log.i(TAG, "Event-loop finished")

                            if (startedByUser) {
                                // Show dismissable disconnected notification
                                TunnelNotification.showDisconnectedNotification(context)
                            }
                        }
                } catch (e: ConnlibException) {
                    Log.e(TAG, "Failed to start session", e)

                    e.close()
                } finally {
                    commandChannel = null
                    tunnelState = State.DOWN
                    unreachableSites.clear()

                    stopNetworkMonitoring()
                    stopDisconnectMonitoring()

                    // Stop the foreground notification
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    private fun sendTunnelCommand(command: TunnelCommand) {
        val commandName = command.javaClass.name

        if (commandChannel == null) {
            Log.d(TAG, "Cannot send $commandName: No active connlib session")
            return
        }

        try {
            commandChannel?.trySend(command)?.getOrThrow()
        } catch (e: Exception) {
            Log.w(TAG, "Cannot send $commandName: ${e.message}")
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

    fun setServiceStateMutableStateFlow(stateFlow: MutableStateFlow<State?>) {
        serviceStateMutableStateFlow = stateFlow

        // Update the newly bound SessionActivity with our current state
        serviceStateMutableStateFlow?.value = tunnelState
    }

    fun setResourcesMutableStateFlow(stateFlow: MutableStateFlow<List<Resource>>) {
        resourcesMutableStateFlow = stateFlow

        // Update the newly bound SessionActivity with our current resources
        resourcesMutableStateFlow?.value = tunnelResources
    }

    private fun updateServiceStateFlow(state: State) {
        serviceStateMutableStateFlow?.value = state
    }

    private fun updateResourcesStateFlow(resources: List<Resource>) {
        resourcesMutableStateFlow?.value = resources
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

    fun startConnectedNotification() {
        val notification = TunnelNotification.createConnectedNotification(this)
        startForeground(TunnelNotification.CONNECTED_NOTIFICATION_ID, notification)
    }

    private fun getDeviceName(): String {
        val deviceName = appRestrictions.getString("deviceName")
        return if (deviceName.isNullOrBlank() || deviceName == "null") {
            Build.MODEL
        } else {
            deviceName
        }
    }

    sealed class TunnelCommand {
        data object Disconnect : TunnelCommand()

        data class SetInternetResourceState(
            val active: Boolean,
        ) : TunnelCommand()

        data class SetDns(
            val dnsServers: List<String>,
        ) : TunnelCommand()

        data class SetLogDirectives(
            val directives: String,
        ) : TunnelCommand()

        data class SetTun(
            val fd: Int,
        ) : TunnelCommand()

        data object Reset : TunnelCommand()
    }

    private fun resourceById(resourceId: String): Pair<Resource, Site>? {
        val resource = _tunnelResources.find { it.id == resourceId } ?: return null
        val site = resource.sites?.firstOrNull() ?: return null
        return Pair(resource, site)
    }

    private fun showErrorNotification(
        title: String,
        message: String,
    ) {
        TunnelNotification.showErrorNotification(this, title, message)
    }

    private suspend fun eventLoop(
        session: SessionInterface,
        commandChannel: Channel<TunnelCommand>,
    ) {
        val eventChannel =
            serviceScope.produce {
                while (isActive) {
                    send(session.nextEvent())
                }
            }

        var running = true

        while (running) {
            try {
                select<Unit> {
                    commandChannel.onReceive { command ->
                        when (command) {
                            is TunnelCommand.Disconnect -> {
                                session.disconnect()
                                // Sending disconnect will close the event-stream which will exit this loop
                            }
                            is TunnelCommand.SetInternetResourceState -> {
                                session.setInternetResourceState(command.active)
                            }
                            is TunnelCommand.SetDns -> {
                                session.setDns(command.dnsServers)
                            }

                            is TunnelCommand.SetLogDirectives -> {
                                session.setLogDirectives(command.directives)
                            }

                            is TunnelCommand.SetTun -> {
                                session.setTun(command.fd)
                            }

                            is TunnelCommand.Reset -> {
                                session.reset("roam")
                            }
                        }
                    }
                    eventChannel.onReceive { event ->
                        event.use { event ->
                            when (event) {
                                is Event.ResourcesUpdated -> {
                                    tunnelResources = event.resources.map { convertResource(it) }
                                    resourcesUpdated()
                                }

                                is Event.TunInterfaceUpdated -> {
                                    tunnelDnsAddresses = event.dns.toMutableList()
                                    tunnelSearchDomain = event.searchDomain
                                    tunnelIpv4Address = event.ipv4
                                    tunnelIpv6Address = event.ipv6
                                    tunnelRoutes.clear()
                                    tunnelRoutes.addAll(
                                        event.ipv4Routes.map { cidr ->
                                            Cidr(
                                                address = cidr.address,
                                                prefix = cidr.prefix.toInt(),
                                            )
                                        },
                                    )
                                    tunnelRoutes.addAll(
                                        event.ipv6Routes.map { cidr ->
                                            Cidr(
                                                address = cidr.address,
                                                prefix = cidr.prefix.toInt(),
                                            )
                                        },
                                    )
                                    buildVpnService()
                                }

                                is Event.Disconnected -> {
                                    // Clear any user tokens and actorNames
                                    repo.clearToken()
                                    repo.clearActorName()

                                    running = false
                                }

                                is Event.GatewayVersionMismatch -> {
                                    val (resource, site) = resourceById(event.resourceId) ?: return@use

                                    if (!unreachableSites.add(site.id)) {
                                        return@use
                                    }

                                    showErrorNotification(
                                        "Failed to connect to '${resource.name}'",
                                        "Your Firezone Client is incompatible with all Gateways in the site '${site.name}'. Please update your Client to the latest version and contact your administrator if the issue persists.",
                                    )
                                }

                                is Event.AllGatewaysOffline -> {
                                    val (resource, site) = resourceById(event.resourceId) ?: return@use

                                    if (!unreachableSites.add(site.id)) {
                                        return@use
                                    }

                                    showErrorNotification(
                                        "Failed to connect to '${resource.name}'",
                                        "All Gateways in the site '${site.name}' are offline. Contact your administrator to resolve this issue.",
                                    )
                                }

                                null -> {
                                    Log.i(TAG, "Event channel closed")
                                    running = false
                                }
                            }
                        }
                    }
                }
            } catch (e: ClosedReceiveChannelException) {
                running = false
            } catch (e: Exception) {
                Log.e(TAG, "Error in event loop", e)
            }
        }
    }

    private fun convertResource(resource: uniffi.connlib.Resource): Resource =
        when (resource) {
            is uniffi.connlib.Resource.Dns ->
                resource.resource.let { r ->
                    Resource(
                        ResourceType.DNS,
                        r.id,
                        r.address,
                        r.addressDescription,
                        r.sites.map { it.toModel() },
                        r.name,
                        r.status.toModel(),
                    )
                }
            is uniffi.connlib.Resource.Cidr ->
                resource.resource.let { r ->
                    Resource(
                        ResourceType.CIDR,
                        r.id,
                        r.address,
                        r.addressDescription,
                        r.sites.map { it.toModel() },
                        r.name,
                        r.status.toModel(),
                    )
                }
            is uniffi.connlib.Resource.Internet ->
                resource.resource.let { r ->
                    Resource(
                        ResourceType.Internet,
                        r.id,
                        null,
                        null,
                        r.sites.map { it.toModel() },
                        r.name,
                        r.status.toModel(),
                    )
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

// UniFFI → Model type conversions

private fun uniffi.connlib.Site.toModel() = Site(id = id, name = name)

private fun uniffi.connlib.ResourceStatus.toModel() =
    when (this) {
        uniffi.connlib.ResourceStatus.UNKNOWN -> StatusEnum.UNKNOWN
        uniffi.connlib.ResourceStatus.ONLINE -> StatusEnum.ONLINE
        uniffi.connlib.ResourceStatus.OFFLINE -> StatusEnum.OFFLINE
    }
