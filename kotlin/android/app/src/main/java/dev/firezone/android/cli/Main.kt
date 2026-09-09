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

// `adb shell` runs as the primary user and this prototype offers no way to name another one.
private const val USER_ID = 0

private const val CALLING_PACKAGE = "com.android.shell"

// A new command is an entry here plus an arm in `execute`, which the compiler asks for because
// the `when` over this is exhaustive. The usage text is built from these, so it cannot fall behind.
private enum class Subcommand(
    val label: String,
    val description: String,
) {
    STATUS("status", "Report who this device is signed in as and which addresses it holds"),
}

object Main {
    @JvmStatic
    fun main(args: Array<String>) {
        // The binder threads this process picked up are not daemons, so returning from `main`
        // would leave it running.
        System.exit(dispatch(args))
    }

    private fun dispatch(args: Array<String>): Int {
        // No command takes arguments of its own yet, so its name is the whole command line.
        val argument = args.singleOrNull()

        if (argument == "--help") {
            println(usage())

            return 0
        }

        val command =
            Subcommand.entries.firstOrNull { it.label == argument }
                ?: run {
                    System.err.println(usage())

                    return 2
                }

        // `app_process` starts a bare VM, so nothing has set up the looper the framework calls
        // below expect to find on this thread. The deprecation is aimed at apps, whose main looper
        // the framework prepares for them.
        @Suppress("DEPRECATION")
        Looper.prepareMainLooper()

        return try {
            println(execute(command))

            0
        } catch (e: Exception) {
            System.err.println("firezone: ${e.message ?: e}")

            1
        }
    }

    private fun execute(command: Subcommand): String =
        when (command) {
            Subcommand.STATUS -> render(fetchStatus())
        }

    private fun usage(): String {
        val column = Subcommand.entries.maxOf { it.label.length } + 2

        return buildString {
            appendLine("usage: firezone <command>")
            appendLine()
            appendLine("commands:")
            Subcommand.entries.forEach { appendLine("  ${it.label.padEnd(column)}${it.description}") }
        }.trimEnd()
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
