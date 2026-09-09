// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.cli

import android.app.IActivityManager
import android.content.AttributionSource
import android.content.IContentProvider
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.os.Process
import com.github.ajalt.clikt.core.CliktError
import com.github.ajalt.clikt.core.Context
import com.github.ajalt.clikt.core.CoreCliktCommand
import com.github.ajalt.clikt.core.parse
import com.github.ajalt.clikt.core.subcommands

// `adb shell` runs as the primary user and this prototype offers no way to name another one.
private const val USER_ID = 0

private const val CALLING_PACKAGE = "com.android.shell"

object Main {
    @JvmStatic
    fun main(args: Array<String>) {
        val firezone = Firezone().subcommands(StatusCommand())

        val code =
            try {
                firezone.parse(args)

                0
            } catch (e: CliktError) {
                val message = firezone.getFormattedHelp(e)

                if (e.statusCode == 0) {
                    println(message)
                } else {
                    System.err.println(message)
                }

                e.statusCode
            }

        // The binder threads this process picked up are not daemons, so returning from `main`
        // would leave it running.
        System.exit(code)
    }
}

private class Firezone : CoreCliktCommand(name = "firezone") {
    override fun run() = Unit
}

private class StatusCommand : CoreCliktCommand(name = "status") {
    override fun help(context: Context): String = "Report who this device is signed in as and which addresses it holds"

    override fun run() {
        // `app_process` starts a bare VM, so nothing has set up the looper the framework calls
        // below expect to find on this thread. The deprecation is aimed at apps, whose main looper
        // the framework prepares for them.
        @Suppress("DEPRECATION")
        Looper.prepareMainLooper()

        val status =
            try {
                fetchStatus()
            } catch (e: Exception) {
                throw CliktError("firezone: ${e.message ?: e}")
            }

        echo(render(status))
    }

    // The same route AOSP's `content` tool takes: `IActivityManager` needs no `Context`, which this
    // process does not have, and it starts the app if it is not already running.
    private fun fetchStatus(): Status {
        val activityManager = activityManager()
        val token = Binder()

        val holder =
            activityManager.getContentProviderExternal(CLI_AUTHORITY, USER_ID, token, "firezone")
                ?: throw IllegalStateException("No provider for $CLI_AUTHORITY. Is the Firezone app installed?")

        try {
            val provider =
                holder.provider
                    ?: throw IllegalStateException("$CLI_AUTHORITY published no provider")
            val reply = handshake(provider) ?: throw IllegalStateException("The app refused the handshake")
            val cli =
                IFirezoneCli.Stub.asInterface(reply.getBinder(BINDER_KEY))
                    ?: throw IllegalStateException("The handshake carried no binder")

            return cli.status()
        } finally {
            activityManager.removeContentProviderExternalAsUser(CLI_AUTHORITY, token, USER_ID)
        }
    }

    // A hidden static on a public class is the one shape the compile-time stubs cannot describe:
    // `android.app.ActivityManager` itself comes from `android.jar`, which omits this method.
    private fun activityManager(): IActivityManager =
        Class
            .forName("android.app.ActivityManager")
            .getMethod("getService")
            .invoke(null) as IActivityManager

    private fun handshake(provider: IContentProvider): Bundle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            throw IllegalStateException(
                "`IContentProvider#call` takes an `AttributionSource` only since API 31, this device is API ${Build.VERSION.SDK_INT}",
            )
        }

        val attributionSource =
            AttributionSource
                .Builder(Process.myUid())
                .setPackageName(CALLING_PACKAGE)
                .build()

        return provider.call(attributionSource, CLI_AUTHORITY, HANDSHAKE_METHOD, null, null)
    }

    private fun render(status: Status): String =
        buildString {
            appendLine("signed-in: ${if (status.signedIn) "yes" else "no"}")
            status.accountSlug?.let { appendLine("account: $it") }
            status.actorName?.let { appendLine("actor: $it") }
            status.tunnelIpv4?.let { appendLine("tunnel-ipv4: $it") }
            status.tunnelIpv6?.let { appendLine("tunnel-ipv6: $it") }
        }.trimEnd()
}
