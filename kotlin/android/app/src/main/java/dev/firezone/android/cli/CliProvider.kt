// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.cli

import android.content.ComponentName
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.model.Resource
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal const val CLI_AUTHORITY = "dev.firezone.android.cli"
internal const val HANDSHAKE_METHOD = "handshake"
internal const val BINDER_KEY = "binder"

private const val PROTOCOL_VERSION = 1
private const val BIND_TIMEOUT_MS = 5_000L
private const val TUNNEL_DOWN = "Tunnel: DOWN"

// The CLI runs outside the app and has no `Context` to reach the tunnel with. A provider is the
// one component the shell can address without one, so the handshake hands it a binder instead.
class CliProvider : ContentProvider() {
    private val cli =
        object : IFirezoneCli.Stub() {
            override fun protocolVersion(): Int = PROTOCOL_VERSION

            override fun status(): String = report(context!!)
        }

    override fun onCreate(): Boolean = true

    override fun call(
        method: String,
        arg: String?,
        extras: Bundle?,
    ): Bundle {
        val uid = Binder.getCallingUid()

        if (uid != Process.SHELL_UID && uid != Process.ROOT_UID) {
            throw SecurityException("uid $uid may not talk to the Firezone CLI")
        }

        if (method != HANDSHAKE_METHOD) {
            throw IllegalArgumentException("Unknown method '$method'")
        }

        return Bundle().apply { putBinder(BINDER_KEY, cli) }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(
        uri: Uri,
        values: ContentValues?,
    ): Uri? = null

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    private fun report(context: Context): String {
        if (!TunnelService.isRunning(context)) {
            return TUNNEL_DOWN
        }

        val connection = TunnelConnection()

        // Flags 0 rather than `BIND_AUTO_CREATE`: asking after the tunnel must never be what
        // starts it.
        if (!context.bindService(Intent(context, TunnelService::class.java), connection, 0)) {
            throw IllegalStateException("The tunnel service is running but refused the binding")
        }

        try {
            val service =
                connection.await()
                    ?: throw IllegalStateException("The tunnel service did not answer within ${BIND_TIMEOUT_MS}ms")

            return describe(service)
        } finally {
            context.unbindService(connection)
        }
    }

    private fun describe(service: TunnelService): String =
        buildString {
            appendLine("Tunnel: ${service.serviceState.value}")

            service.actorNameState.value?.let { appendLine("Signed in as: $it") }

            val resources = service.resourcesState.value
            appendLine("Resources: ${resources.size}")
            resources.forEach { appendLine("  ${describe(it)}") }

            val devices = service.connectedDevicesState.value
            if (devices.isNotEmpty()) {
                appendLine("Connected devices: ${devices.size}")
                devices.forEach { appendLine("  ${it.name} (${it.tunIpv4})") }
            }
        }.trimEnd()

    private fun describe(resource: Resource): String = resource.address?.let { "${resource.name} ($it)" } ?: resource.name

    // The AIDL call arrives on a binder thread, which is the only one allowed to wait here:
    // `onServiceConnected` is dispatched on the main thread.
    private class TunnelConnection : ServiceConnection {
        private val connected = CountDownLatch(1)

        @Volatile
        private var service: TunnelService? = null

        override fun onServiceConnected(
            name: ComponentName?,
            binder: IBinder?,
        ) {
            service = (binder as TunnelService.LocalBinder).getService()
            connected.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName?) {}

        fun await(): TunnelService? = if (connected.await(BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS)) service else null
    }
}
