// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.tunnel

import NetworkMonitor
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.ParcelFileDescriptor
import com.google.android.gms.tasks.Tasks
import com.google.firebase.installations.FirebaseInstallations
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.Log
import dev.firezone.android.core.Telemetry
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.isEnabled
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfiguration
import dev.firezone.android.core.data.model.SessionCredential
import dev.firezone.android.core.data.model.shouldClearSavedCredentials
import dev.firezone.android.core.x509.X509Identity
import dev.firezone.android.core.x509.X509IdentityException
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.ConnectedDevice
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.Site
import dev.firezone.android.tunnel.model.StatusEnum
import dev.firezone.android.tunnel.model.isInternetResource
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.channels.produce
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import uniffi.connlib.AndroidSessionConfig
import uniffi.connlib.ConnlibException
import uniffi.connlib.DeviceInfo
import uniffi.connlib.Event
import uniffi.connlib.ProtectSocket
import uniffi.connlib.SessionInterface
import uniffi.connlib.configureLogger
import uniffi.connlib.enforceLogSizeCap
import uniffi.connlib.isLogStreamingActive
import uniffi.connlib.logCleanupDefaultIntervalSecs
import uniffi.connlib.logCleanupDefaultMaxSizeMb
import uniffi.connlib.startTelemetry
import uniffi.connlib.stopTelemetry
import uniffi.connlib.use
import java.nio.file.Files
import java.nio.file.Paths
import javax.inject.Inject
import javax.inject.Provider
import kotlin.coroutines.cancellation.CancellationException

@AndroidEntryPoint
@OptIn(ExperimentalStdlibApi::class)
class TunnelService : VpnService() {
    @Inject
    internal lateinit var repo: Repository

    @Inject
    internal lateinit var managedConfigurationSource: ManagedConfigurationSource

    @Inject
    internal lateinit var moshi: Moshi

    @Inject
    internal lateinit var sessionFactory: SessionFactory

    @Inject
    internal lateinit var x509Identity: X509Identity

    // A provider rather than the bundle itself: an admin can change the restrictions while the
    // service runs, so every connection has to read them again.
    @Inject
    internal lateinit var applicationRestrictions: Provider<Bundle>

    private var tunnelIpv4Address: String? = null
    private var tunnelIpv6Address: String? = null
    private var tunnelDnsAddresses: MutableList<String> = mutableListOf()
    private var tunnelSearchDomain: String? = null
    private var tunnelRoutes: MutableList<Cidr> = mutableListOf()
    private var resourceState: ResourceState = ResourceState.UNSET

    // For reacting to changes to the network
    private var networkCallback: NetworkMonitor? = null

    private var logCleanupJob: Job? = null
    private var featureFlagPollJob: Job? = null

    var startedByUser: Boolean = false

    // A `SupervisorJob` keeps one failed child from cancelling its siblings, but an exception it
    // does not handle still reaches the thread's default handler and takes the process with it.
    // Reporting the failure and leaving the service to reset its own state is always better than
    // killing the app underneath the user.
    private val serviceExceptionHandler =
        CoroutineExceptionHandler { _, throwable ->
            Log.e(TAG, "Unhandled exception in the tunnel service", throwable)
        }
    private val serviceScope = CoroutineScope(SupervisorJob() + serviceExceptionHandler)
    private val connectionState = ManagedConnectionState<ConnectionParameters>()
    private val appliedManagedConfigurationRevision = MutableStateFlow(0L)
    private val tunnelConfigurationLock = Any()

    @Volatile
    private var latestStartId = 0

    private val _serviceState = MutableStateFlow(State.DOWN)
    private val _resourcesState = MutableStateFlow<List<Resource>>(emptyList())
    private val _connectedDevicesState = MutableStateFlow<List<ConnectedDevice>>(emptyList())
    private val _actorNameState = MutableStateFlow<String?>(null)

    // A `StateFlow` replays its current value to every new collector, so a newly bound SessionActivity catches up on its own.
    val serviceState: StateFlow<State> = _serviceState.asStateFlow()
    val resourcesState: StateFlow<List<Resource>> = _resourcesState.asStateFlow()
    val connectedDevicesState: StateFlow<List<ConnectedDevice>> = _connectedDevicesState.asStateFlow()
    val actorNameState: StateFlow<String?> = _actorNameState.asStateFlow()

    var tunnelResources: List<Resource>
        get() = _resourcesState.value
        set(value) {
            _resourcesState.value = value
        }
    var tunnelConnectedDevices: List<ConnectedDevice>
        get() = _connectedDevicesState.value
        set(value) {
            _connectedDevicesState.value = value
        }
    var tunnelActorName: String?
        get() = _actorNameState.value
        set(value) {
            _actorNameState.value = value
        }
    var tunnelState: State
        get() = _serviceState.value
        set(value) {
            _serviceState.value = value
        }

    // For binding the SessionActivity view to this service
    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): TunnelService = this@TunnelService
    }

    // The system binds with `SERVICE_INTERFACE` to obtain `VpnService`'s own binder, which is what
    // it transacts on to dispatch `onRevoke`. Only the SessionActivity's bind gets `LocalBinder`.
    override fun onBind(intent: Intent): IBinder? =
        if (intent.action == VpnService.SERVICE_INTERFACE) {
            super.onBind(intent)
        } else {
            binder
        }

    private fun buildVpnService(connection: ConnectionParameters) {
        synchronized(tunnelConfigurationLock) {
            if (!connectionState.isActive(connection)) {
                return
            }

            val managedConfiguration = connectionState.managedConfiguration()
            val ipv4Address = tunnelIpv4Address ?: return
            val ipv6Address = tunnelIpv6Address ?: return

            val builder =
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
                    }

            val applicationRoutingPolicy = managedConfiguration.applicationRoutingPolicy()
            if (applicationRoutingPolicy.hasConflict) {
                Log.w(TAG, "Both managed application lists are set; using the allow list")
            }
            val hasValidApplicationRouting =
                applicationRoutingPolicy.apply(
                    addAllowed = { packageName ->
                        tryAddApplication(packageName) { builder.addAllowedApplication(packageName) }
                    },
                    addDisallowed = { packageName ->
                        tryAddApplication(packageName) { builder.addDisallowedApplication(packageName) }
                    },
                )
            if (!hasValidApplicationRouting) {
                Log.e(TAG, "Managed VPN allow list has no installed applications; keeping the current interface")
                return
            }

            builder
                .apply {
                    tunnelRoutes.forEach {
                        addRoute(it.address, it.prefix)
                    }

                    tunnelDnsAddresses.forEach { dns ->
                        addDnsServer(dns)
                    }

                    tunnelSearchDomain?.let {
                        addSearchDomain(it)
                    }

                    addAddress(ipv4Address, 32)
                    addAddress(ipv6Address, 128)
                }.runCatching { establish() }
                .onFailure { Log.e(TAG, "Error establishing VPN service", it) }
                .onSuccess { fd ->
                    if (fd == null) {
                        Log.d(TAG, "VpnService.Builder.establish() returned null")
                        return@onSuccess
                    }

                    val ownedFd = OwnedTunFileDescriptor(fd.detachFd(), ::closeTunFileDescriptor)
                    if (
                        !connectionState.runIfActive(connection) {
                            sendTunnelCommand(connection.commandChannel, TunnelCommand.SetTun(ownedFd))
                        }
                    ) {
                        ownedFd.close()
                    }
                }
        }
    }

    private fun closeTunFileDescriptor(fd: Int) {
        runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
            .onFailure { Log.w(TAG, "Failed to close an undelivered TUN file descriptor", it) }
    }

    private fun tryAddApplication(
        packageName: String,
        addApplication: () -> Unit,
    ): Boolean =
        try {
            addApplication()
            true
        } catch (_: PackageManager.NameNotFoundException) {
            Log.w(TAG, "Ignoring unavailable application in managed VPN policy: $packageName")
            false
        }

    private fun applyManagedConfiguration(configuration: ManagedConfiguration) {
        val update = connectionState.apply(configuration) ?: return
        if (update.requiresReconnect) {
            Log.i(TAG, "Reconnecting to apply managed configuration")
            sendTunnelCommand(update.owner.commandChannel, TunnelCommand.Disconnect)
            return
        }
        if (update.updateLogFilter) {
            sendTunnelCommand(
                update.owner.commandChannel,
                TunnelCommand.SetLogDirectives(
                    repo.getEffectiveConfig(repo.getUserConfigSync(), configuration).logFilter,
                ),
            )
        }
        if (update.rebuildVpn) {
            buildVpnService(update.owner)
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
        val startRequest = connectionState.requestStart()
        latestStartId = startId
        serviceScope.launch {
            val update = managedConfigurationSource.refreshUpdate()
            appliedManagedConfigurationRevision.first { it >= update.revision }
            if (!connect(startRequest)) {
                connectionState.stopIfIdle { stopSelfResult(startId) }
            }
        }
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        activeService = this

        serviceScope.launch {
            managedConfigurationSource.updates.filterNotNull().collect { update ->
                try {
                    applyManagedConfiguration(update.configuration)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to apply managed configuration", e)
                } finally {
                    appliedManagedConfigurationRevision.value = update.revision
                }
            }
        }

        // `Telemetry.start` honours this for the Kotlin side; connlib's telemetry is a separate
        // client, so without this a build stamped as not reporting still reports.
        if (!BuildConfig.NO_TELEMETRY) {
            startTelemetry(protectSocketCallback)
        }
    }

    override fun onDestroy() {
        activeService = null
        serviceScope.cancel()

        if (!BuildConfig.NO_TELEMETRY) {
            stopTelemetry()
        }
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
        val connection = connectionState.disconnect()
        if (connection == null) {
            Log.d(TAG, "Cannot send ${TunnelCommand.Disconnect.javaClass.name}: No active connlib session")
            return
        }

        sendTunnelCommand(connection.commandChannel, TunnelCommand.Disconnect)
    }

    fun setDns(dnsList: List<String>) {
        sendTunnelCommand(TunnelCommand.SetDns(dnsList))
    }

    fun reset() {
        sendTunnelCommand(TunnelCommand.Reset)
    }

    private fun connect(startRequest: Long): Boolean =
        when (val claim = connectionState.claim(startRequest, ::createConnection)) {
            ConnectionClaim.Unavailable -> {
                false
            }

            is ConnectionClaim.Existing -> {
                true
            }

            is ConnectionClaim.Started -> {
                startConnection(claim.owner)
                true
            }
        }

    private fun createConnection(managedConfiguration: ManagedConfiguration): ConnectionParameters? {
        val credential = managedConfiguration.resolveSessionCredential(repo.getTokenSync())
        val certificateAlias = repo.getX509CertificateAliasSync(applicationRestrictions.get())

        if (credential == null) {
            return null
        }

        return ConnectionParameters(
            commandChannel =
                Channel(
                    capacity = Channel.UNLIMITED,
                    onUndeliveredElement = { command -> command.closeOwnedResources() },
                ),
            credential = credential,
            certificateAlias = certificateAlias,
            config = repo.getEffectiveConfig(repo.getUserConfigSync(), managedConfiguration),
            resourceState = repo.getInternetResourceStateSync(),
            managedConfiguration = managedConfiguration,
        )
    }

    private fun startConnection(connection: ConnectionParameters) {
        resourceState = connection.resourceState

        tunnelState = State.CONNECTING
        // Dismiss any previous disconnected notifications
        TunnelNotification.dismissDisconnectedNotification(this)

        val context = this

        serviceScope.launch {
            try {
                // Set telemetry environment and user context
                val deviceIdValue = deviceId()
                Telemetry.setEnvironmentOrClose(connection.config.apiUrl)
                Telemetry.setFirezoneId(deviceIdValue)
                // The portal names the account in `init`; until then this session has none.
                Telemetry.setAccountSlug(null)

                configureLogger(
                    logDir(this@TunnelService),
                    connection.config.logFilter,
                    flowLogsDir(this@TunnelService),
                )

                val deviceInfo =
                    DeviceInfo(
                        firebaseInstallationId = firebaseInstallationId(),
                        deviceUuid = null,
                        deviceSerial = null,
                        identifierForVendor = null,
                    )

                // The KeyChain blocks on a system service and connlib reads the identity while
                // it constructs the session, so load it before we get there.
                val certificate = withContext(Dispatchers.IO) { x509Identity.load(connection.certificateAlias) }

                sessionFactory
                    .open(
                        AndroidSessionConfig(
                            apiUrl = connection.config.apiUrl,
                            token = connection.credential.token,
                            deviceId = deviceIdValue,
                            deviceName = getDeviceName(connection.managedConfiguration),
                            isInternetResourceActive = resourceState.isEnabled(),
                            deviceInfo = deviceInfo,
                        ),
                        // The token authenticates the user. A configured certificate attests
                        // the device, and the portal decides whether to accept it.
                        tlsIdentity = certificate?.tlsIdentity,
                    ).use { session ->
                        startNetworkMonitoring()
                        startLogCleanup()
                        startFeatureFlagPoll()

                        val stopReason = eventLoop(session, connection)

                        Log.i(TAG, "Event-loop finished: $stopReason")

                        val message =
                            when (stopReason) {
                                is StopReason.Disconnected -> stopReason.message

                                StopReason.Error -> UNRECOVERABLE_ERROR

                                StopReason.ExplicitDisconnect,
                                StopReason.EventChannelClosed,
                                StopReason.CommandChannelClosed,
                                -> null
                            }

                        if (startedByUser && message != null) {
                            TunnelNotification.showDisconnectedNotification(context, message)
                        }
                    }
            } catch (e: ConnlibException) {
                Log.e(TAG, "Failed to start session", e)
                e.close()
            } catch (e: X509IdentityException) {
                Log.e(TAG, "Failed to load the client certificate", e)
                val advice = "Contact your administrator for support."
                showErrorNotification(
                    "Client certificate unavailable",
                    e.message?.takeUnless(String::isBlank)?.let { "$it $advice" } ?: advice,
                )
            } finally {
                beginConnectionCompletion(connection)
                stopNetworkMonitoring()
                stopFeatureFlagPoll()
                stopLogCleanup()
                clearTunnelConfiguration(connection)
                completeConnection(connection)
            }
        }
    }

    private fun beginConnectionCompletion(connection: ConnectionParameters) {
        connectionState.beginCompletion(connection)
        connection.commandChannel.cancel()
    }

    private fun completeConnection(connection: ConnectionParameters) {
        when (val completion = connectionState.complete(connection, ::createConnection)) {
            ConnectionCompletion.Stale -> {
                Unit
            }

            ConnectionCompletion.Stopped -> {
                connectionState.stopIfIdle {
                    if (stopSelfResult(latestStartId)) {
                        tunnelState = State.DOWN
                        stopForeground(STOP_FOREGROUND_REMOVE)
                    }
                }
            }

            is ConnectionCompletion.Restarted -> {
                startConnection(completion.owner)
            }
        }
    }

    private fun clearTunnelConfiguration(connection: ConnectionParameters) {
        synchronized(tunnelConfigurationLock) {
            if (!connectionState.isCurrent(connection)) {
                return
            }

            tunnelIpv4Address = null
            tunnelIpv6Address = null
            tunnelDnsAddresses.clear()
            tunnelSearchDomain = null
            tunnelRoutes.clear()
            tunnelResources = emptyList()
            tunnelConnectedDevices = emptyList()
        }
    }

    private fun sendTunnelCommand(command: TunnelCommand) {
        val connection = connectionState.owner()
        if (connection == null) {
            Log.d(TAG, "Cannot send ${command.javaClass.name}: No active connlib session")
            command.closeOwnedResources()
            return
        }

        sendTunnelCommand(connection.commandChannel, command)
    }

    private fun sendTunnelCommand(
        commandChannel: Channel<TunnelCommand>,
        command: TunnelCommand,
    ): Boolean {
        val commandName = command.javaClass.name
        val result = commandChannel.trySend(command)
        if (result.isSuccess) {
            return true
        }

        command.closeOwnedResources()
        Log.w(TAG, "Cannot send $commandName: ${result.exceptionOrNull()?.message}")
        return false
    }

    private fun TunnelCommand.closeOwnedResources() {
        if (this is TunnelCommand.SetTun) {
            fd.close()
        }
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

    private fun startLogCleanup() {
        logCleanupJob =
            serviceScope.launch(Dispatchers.IO) {
                try {
                    val dir = logDir(this@TunnelService)
                    val maxSizeMb = logCleanupDefaultMaxSizeMb()
                    val intervalMs = logCleanupDefaultIntervalSecs().toLong() * 1000
                    while (isActive) {
                        try {
                            val bytesDeleted = enforceLogSizeCap(listOf(dir), maxSizeMb)
                            if (bytesDeleted > 0u) {
                                Log.d(TAG, "Log cleanup deleted $bytesDeleted bytes")
                            }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Log.w(TAG, "Log cleanup failed", e)
                        }
                        delay(intervalMs)
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.e(TAG, "Log cleanup could not start", e)
                }
            }
    }

    private fun stopLogCleanup() {
        logCleanupJob?.cancel()
        logCleanupJob = null
    }

    private fun startFeatureFlagPoll() {
        featureFlagPollJob =
            serviceScope.launch(Dispatchers.IO) {
                while (isActive) {
                    val active = isLogStreamingActive()
                    Log.setStreamingActive(active)
                    delay(FEATURE_FLAG_POLL_INTERVAL_MS)
                }
            }
    }

    private fun stopFeatureFlagPoll() {
        featureFlagPollJob?.cancel()
        featureFlagPollJob = null
        Log.setStreamingActive(false)
    }

    // `Tasks.await` throws when called on the main thread, which is the thread `onStartCommand`
    // runs `connect` on.
    private suspend fun firebaseInstallationId(): String? =
        withContext(Dispatchers.IO) {
            runCatching { Tasks.await(FirebaseInstallations.getInstance().id) }
                .getOrElse { exception ->
                    Log.d(TAG, "Failed to obtain firebase installation id: $exception")
                    null
                }
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

    fun startConnectedNotification() {
        val notification = TunnelNotification.createConnectedNotification(this)
        startForeground(TunnelNotification.CONNECTED_NOTIFICATION_ID, notification)
    }

    private fun getDeviceName(managedConfiguration: ManagedConfiguration): String {
        val deviceName = managedConfiguration.deviceName
        return if (deviceName.isNullOrBlank() || deviceName == "null") {
            Build.MODEL
        } else {
            deviceName
        }
    }

    internal sealed class TunnelCommand {
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
            val fd: OwnedTunFileDescriptor,
        ) : TunnelCommand()

        data object Reset : TunnelCommand()
    }

    sealed class StopReason {
        data object ExplicitDisconnect : StopReason()

        data class Disconnected(
            val message: String,
        ) : StopReason()

        data object EventChannelClosed : StopReason()

        data object CommandChannelClosed : StopReason()

        data object Error : StopReason()
    }

    private data class ConnectionParameters(
        val commandChannel: Channel<TunnelCommand>,
        val credential: SessionCredential,
        val certificateAlias: String?,
        val config: Config,
        val resourceState: ResourceState,
        val managedConfiguration: ManagedConfiguration,
    )

    private fun resourceById(resourceId: String): Pair<Resource, Site>? {
        val resource = tunnelResources.find { it.id == resourceId } ?: return null
        val site = resource.sites?.firstOrNull() ?: return null
        return Pair(resource, site)
    }

    private fun showErrorNotification(
        title: String,
        message: String,
    ) {
        TunnelNotification.showErrorNotification(this, title, message)
    }

    private fun updateTunnelConfiguration(
        connection: ConnectionParameters,
        event: Event.TunInterfaceUpdated,
    ) {
        synchronized(tunnelConfigurationLock) {
            if (!connectionState.isCurrent(connection)) {
                return
            }

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
            buildVpnService(connection)
        }
    }

    private suspend fun eventLoop(
        session: SessionInterface,
        connection: ConnectionParameters,
    ): StopReason {
        try {
            return runEventLoop(session, connection)
        } finally {
            beginConnectionCompletion(connection)
        }
    }

    private suspend fun runEventLoop(
        session: SessionInterface,
        connection: ConnectionParameters,
    ): StopReason {
        val commandChannel = connection.commandChannel

        @OptIn(ExperimentalCoroutinesApi::class)
        val eventChannel =
            serviceScope.produce {
                while (isActive) {
                    send(session.nextEvent())
                }
            }

        var explicitDisconnect = false
        var stopReason: StopReason? = null

        while (stopReason == null) {
            try {
                select<Unit> {
                    commandChannel.onReceive { command ->
                        try {
                            when (command) {
                                is TunnelCommand.Disconnect -> {
                                    explicitDisconnect = true
                                    session.disconnect()

                                    // Sending disconnect will close the event-stream which will exit this loop.
                                    // We don't want to bail out here right away to allow connlib to clean up after itself.
                                }

                                is TunnelCommand.SetInternetResourceState -> {
                                    session.setInternetResourceState(command.active)
                                }

                                is TunnelCommand.SetDns -> {
                                    session.setDns(command.dnsServers)
                                }

                                is TunnelCommand.SetLogDirectives -> {
                                    configureLogger(
                                        logDir(this@TunnelService),
                                        command.directives,
                                        flowLogsDir(this@TunnelService),
                                    )
                                }

                                is TunnelCommand.SetTun -> {
                                    command.fd.transferTo(session::setTun)
                                }

                                is TunnelCommand.Reset -> {
                                    session.reset("roam")
                                }
                            }
                        } finally {
                            command.closeOwnedResources()
                        }
                    }
                    eventChannel.onReceive { event ->
                        event.use { event ->
                            when (event) {
                                is Event.ResourcesUpdated -> {
                                    tunnelResources = event.resources.map { convertResource(it) }
                                    tunnelConnectedDevices =
                                        event.connectedDevices.map { convertConnectedDevice(it) }
                                    resourcesUpdated()
                                }

                                is Event.TunInterfaceUpdated -> {
                                    updateTunnelConfiguration(connection, event)
                                }

                                is Event.ConnectedToPortal -> {
                                    Telemetry.setAccountSlug(event.accountSlug)
                                    tunnelActorName = event.actorName

                                    // A slug forced through managed configuration already wins
                                    // every read, so caching over it would only surface once the
                                    // admin stops forcing one.
                                    if (!repo.isAccountSlugManaged()) {
                                        repo.saveAccountSlug(event.accountSlug).collect {}
                                    }
                                }

                                is Event.Disconnected -> {
                                    if (
                                        connection.credential.origin.shouldClearSavedCredentials(
                                            event.error.requiresSignIn(),
                                        )
                                    ) {
                                        repo.clearToken()
                                    }

                                    stopReason = StopReason.Disconnected(event.error.message())
                                }

                                is Event.GatewayVersionMismatch -> {
                                    val (resource, site) = resourceById(event.resourceId) ?: return@use

                                    showErrorNotification(
                                        "Failed to connect to '${resource.name}'",
                                        "Your Firezone Client is incompatible with all Gateways in the site '${site.name}'. Please update your Client to the latest version and contact your administrator if the issue persists.",
                                    )
                                }

                                is Event.AllGatewaysOffline -> {
                                    val (resource, site) = resourceById(event.resourceId) ?: return@use

                                    showErrorNotification(
                                        "Failed to connect to '${resource.name}'",
                                        "All Gateways in the site '${site.name}' are offline. Contact your administrator to resolve this issue.",
                                    )
                                }

                                null -> {
                                    Log.i(TAG, "Event channel closed")
                                    stopReason = StopReason.EventChannelClosed
                                }
                            }
                        }
                    }
                }
            } catch (e: ClosedReceiveChannelException) {
                stopReason = StopReason.CommandChannelClosed
            } catch (e: CancellationException) {
                stopReason = StopReason.CommandChannelClosed
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Error in event loop", e)
                stopReason = StopReason.Error
            }
        }

        return if (explicitDisconnect) {
            StopReason.ExplicitDisconnect
        } else {
            stopReason
        }
    }

    private fun convertConnectedDevice(device: uniffi.connlib.ConnectedDevice): ConnectedDevice =
        ConnectedDevice(
            id = device.id,
            name = device.name,
            tunIpv4 = device.tunIpv4,
            tunIpv6 = device.tunIpv6,
            pools = device.pools,
        )

    private fun convertResource(resource: uniffi.connlib.Resource): Resource =
        when (resource) {
            is uniffi.connlib.Resource.Dns -> {
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
            }

            is uniffi.connlib.Resource.Cidr -> {
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
            }

            is uniffi.connlib.Resource.Internet -> {
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

        // Whatever the event loop threw reads like a stack trace, so the user is told that the
        // session ended rather than what raised it.
        private const val UNRECOVERABLE_ERROR: String = "Firezone ran into an unrecoverable error."
        private const val FEATURE_FLAG_POLL_INTERVAL_MS: Long = 5_000

        fun logDir(context: Context): String {
            val logDir = context.cacheDir.absolutePath + "/logs"
            Files.createDirectories(Paths.get(logDir))
            return logDir
        }

        // Under `filesDir` (persistent) and outside the log directory so exported
        // log bundles never sweep the spool up.
        fun flowLogsDir(context: Context): String {
            val flowLogsDir = context.filesDir.absolutePath + "/flow_logs"
            Files.createDirectories(Paths.get(flowLogsDir))
            return flowLogsDir
        }

        @Volatile
        private var activeService: TunnelService? = null

        // Protects through the one live service; the session, telemetry, and
        // flow-log drains all share it. Without a running service our VPN cannot
        // be up, so the no-op is the correct bypass then too.
        val protectSocketCallback: ProtectSocket = VpnProtectSocket { fd -> activeService?.protect(fd) }

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
