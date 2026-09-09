// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.cli

import android.content.AttributionSource
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Looper
import android.os.Process
import java.lang.reflect.InvocationTargetException

private const val USAGE = "usage: firezone status"

// `adb shell` runs as the primary user and this prototype offers no way to name another one.
private const val USER_ID = 0

private const val CALLING_PACKAGE = "com.android.shell"

object Main {
    @JvmStatic
    fun main(args: Array<String>) {
        val code = execute(args)

        // The binder threads this process picked up are not daemons, so returning from `main`
        // would leave it running.
        System.exit(code)
    }

    private fun execute(args: Array<String>): Int {
        if (args.size != 1 || args[0] != "status") {
            System.err.println(USAGE)

            return 2
        }

        // `app_process` starts a bare VM, so nothing has set up the looper the framework calls
        // below expect to find on this thread. The deprecation is aimed at apps, whose main looper
        // the framework prepares for them.
        @Suppress("DEPRECATION")
        Looper.prepareMainLooper()

        return try {
            println(render(status()))

            0
        } catch (e: Exception) {
            // Reflection reports whatever the app threw wrapped, and the wrapper carries no message.
            val failure = (e as? InvocationTargetException)?.cause ?: e

            System.err.println("firezone: ${failure.message ?: failure}")

            1
        }
    }

    // The same route AOSP's `content` tool takes: `IActivityManager` needs no `Context`, which this
    // process does not have, and it starts the app if it is not already running.
    private fun status(): Status {
        val activityManager =
            Class
                .forName("android.app.ActivityManager")
                .getMethod("getService")
                .invoke(null)
        val iActivityManager = Class.forName("android.app.IActivityManager")
        val token = Binder()

        val holder =
            iActivityManager
                .getMethod(
                    "getContentProviderExternal",
                    String::class.java,
                    Int::class.javaPrimitiveType,
                    IBinder::class.java,
                    String::class.java,
                ).invoke(activityManager, CLI_AUTHORITY, USER_ID, token, "firezone")
                ?: throw IllegalStateException("No provider for $CLI_AUTHORITY. Is the Firezone app installed?")

        try {
            val provider =
                holder.javaClass.getField("provider").get(holder)
                    ?: throw IllegalStateException("$CLI_AUTHORITY published no provider")
            val reply = handshake(provider) ?: throw IllegalStateException("The app refused the handshake")
            val cli =
                IFirezoneCli.Stub.asInterface(reply.getBinder(BINDER_KEY))
                    ?: throw IllegalStateException("The handshake carried no binder")

            return cli.status()
        } finally {
            iActivityManager
                .getMethod(
                    "removeContentProviderExternalAsUser",
                    String::class.java,
                    IBinder::class.java,
                    Int::class.javaPrimitiveType,
                ).invoke(activityManager, CLI_AUTHORITY, token, USER_ID)
        }
    }

    private fun handshake(provider: Any): Bundle? {
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

        return Class
            .forName("android.content.IContentProvider")
            .getMethod(
                "call",
                AttributionSource::class.java,
                String::class.java,
                String::class.java,
                String::class.java,
                Bundle::class.java,
            ).invoke(provider, attributionSource, CLI_AUTHORITY, HANDSHAKE_METHOD, null, null) as Bundle?
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
