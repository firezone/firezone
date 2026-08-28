// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import dev.firezone.android.core.data.model.ManagedConfiguration

internal sealed interface ConnectionClaim<out T> {
    data object Unavailable : ConnectionClaim<Nothing>

    data class Existing<T>(
        val owner: T,
    ) : ConnectionClaim<T>

    data class Started<T>(
        val owner: T,
    ) : ConnectionClaim<T>
}

internal sealed interface ConnectionCompletion<out T> {
    data object Stale : ConnectionCompletion<Nothing>

    data object Stopped : ConnectionCompletion<Nothing>

    data class Restarted<T>(
        val owner: T,
    ) : ConnectionCompletion<T>
}

internal data class ManagedConnectionUpdate<T>(
    val owner: T,
    val requiresReconnect: Boolean,
    val updateLogFilter: Boolean,
    val rebuildVpn: Boolean,
)

internal class ManagedConnectionState<T : Any> {
    private val lock = Any()
    private var managedConfiguration = ManagedConfiguration()
    private var owner: T? = null
    private var desiredRunning = false
    private var reconnectRequested = false
    private var finishing = false
    private var latestStartRequest = 0L

    fun apply(configuration: ManagedConfiguration): ManagedConnectionUpdate<T>? =
        synchronized(lock) {
            val previous = managedConfiguration
            managedConfiguration = configuration

            val currentOwner = owner ?: return@synchronized null
            if (configuration == previous || !desiredRunning) {
                return@synchronized null
            }

            val requiresReconnect = configuration.requiresSessionReconnect(previous)
            if (requiresReconnect) {
                reconnectRequested = true
            }

            ManagedConnectionUpdate(
                owner = currentOwner,
                requiresReconnect = requiresReconnect,
                updateLogFilter = configuration.logFilter != previous.logFilter,
                rebuildVpn = configuration.requiresVpnRebuild(previous),
            )
        }

    fun claim(
        startRequest: Long,
        create: (ManagedConfiguration) -> T?,
    ): ConnectionClaim<T> =
        synchronized(lock) {
            owner?.let {
                if (!desiredRunning) {
                    reconnectRequested = true
                }
                desiredRunning = true
                return@synchronized ConnectionClaim.Existing(it)
            }

            val newOwner = create(managedConfiguration)
            if (newOwner == null) {
                if (startRequest == latestStartRequest) {
                    desiredRunning = false
                    reconnectRequested = false
                }
                return@synchronized ConnectionClaim.Unavailable
            }
            desiredRunning = true
            owner = newOwner
            finishing = false
            ConnectionClaim.Started(newOwner)
        }

    fun requestStart(): Long =
        synchronized(lock) {
            latestStartRequest += 1
            if (owner != null && (finishing || !desiredRunning)) {
                reconnectRequested = true
            }
            desiredRunning = true
            latestStartRequest
        }

    fun disconnect(): T? =
        synchronized(lock) {
            desiredRunning = false
            reconnectRequested = false
            owner
        }

    fun beginCompletion(expectedOwner: T) {
        synchronized(lock) {
            if (owner === expectedOwner) {
                finishing = true
            }
        }
    }

    fun complete(
        expectedOwner: T,
        create: (ManagedConfiguration) -> T?,
    ): ConnectionCompletion<T> =
        synchronized(lock) {
            if (owner !== expectedOwner) {
                return@synchronized ConnectionCompletion.Stale
            }

            owner = null
            finishing = false
            if (!desiredRunning || !reconnectRequested) {
                desiredRunning = false
                reconnectRequested = false
                return@synchronized ConnectionCompletion.Stopped
            }

            reconnectRequested = false
            val newOwner = create(managedConfiguration)
            if (newOwner == null) {
                desiredRunning = false
                return@synchronized ConnectionCompletion.Stopped
            }

            owner = newOwner
            ConnectionCompletion.Restarted(newOwner)
        }

    fun stopIfIdle(stop: () -> Unit): Boolean =
        synchronized(lock) {
            if (owner != null || desiredRunning) {
                return@synchronized false
            }

            stop()
            true
        }

    fun owner(): T? = synchronized(lock) { owner }

    fun isCurrent(expectedOwner: T): Boolean = synchronized(lock) { owner === expectedOwner }

    fun managedConfiguration(): ManagedConfiguration = synchronized(lock) { managedConfiguration }
}
