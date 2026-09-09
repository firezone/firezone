// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.cli

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.tunnel.TunnelService

internal const val CLI_AUTHORITY = "dev.firezone.android.cli"
internal const val HANDSHAKE_METHOD = "handshake"
internal const val BINDER_KEY = "binder"

private const val PROTOCOL_VERSION = 1

// `Process.SHELL_UID` and `Process.ROOT_UID` name these, but only since API 29, and the app
// supports 26.
private const val SHELL_UID = 2000
private const val ROOT_UID = 0

// Providers are created before `Application.onCreate`, so `@AndroidEntryPoint` cannot inject one.
// The graph is up by the time a transaction arrives, which is why this is resolved per call.
@EntryPoint
@InstallIn(SingletonComponent::class)
internal interface CliEntryPoint {
    fun tokenStore(): TokenStore

    fun repository(): Repository
}

// The CLI runs outside the app and has no `Context` to reach the tunnel with. A provider is the
// one component the shell can address without one, so the handshake hands it a binder instead.
class CliProvider : ContentProvider() {
    private val cli =
        object : IFirezoneCli.Stub() {
            override fun protocolVersion(): Int = PROTOCOL_VERSION

            override fun status(): Status = report(context!!)
        }

    override fun onCreate(): Boolean = true

    override fun call(
        method: String,
        arg: String?,
        extras: Bundle?,
    ): Bundle {
        val uid = Binder.getCallingUid()

        if (uid != SHELL_UID && uid != ROOT_UID) {
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

    // The provider shares its process with the tunnel, so it reads the live service rather than
    // binding to reach an object this process already holds. Nothing here can start the tunnel,
    // which is the point: asking after it must not be what brings it up.
    private fun report(context: Context): Status {
        val app = EntryPointAccessors.fromApplication(context, CliEntryPoint::class.java)
        val service = TunnelService.running()
        val accountSlug = app.repository().getConfigSync().accountSlug

        return Status(
            signedIn = app.tokenStore().get() != null,
            accountSlug = accountSlug.ifEmpty { null },
            actorName = service?.actorNameState?.value,
            tunnelIpv4 = service?.tunnelIpv4State?.value,
            tunnelIpv6 = service?.tunnelIpv6State?.value,
        )
    }
}
