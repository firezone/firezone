// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import java.util.concurrent.TimeUnit

// The tunnel runs as a `systemExempted` foreground service, which the platform only lets an app
// start while it holds VPN consent. Without this the first `startForeground` throws and takes the
// whole instrumentation process with it.
fun grantVpnConsent() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()

    UiDevice
        .getInstance(instrumentation)
        .executeShellCommand("appops set ${instrumentation.targetContext.packageName} ACTIVATE_VPN allow")
}

fun startTunnelService() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext

    context.startService(Intent(context, TunnelService::class.java))
}

// A started service outlives the test that started it, so without this the next test would drive
// whatever the previous one left running.
fun stopTunnelService() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    context.stopService(Intent(context, TunnelService::class.java))

    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)

    while (TunnelService.isRunning(context)) {
        if (System.nanoTime() > deadline) {
            throw AssertionError("The tunnel service is still running: ${describeTunnelService(context)}")
        }

        Thread.sleep(50)
    }
}

@Suppress("DEPRECATION")
private fun describeTunnelService(context: Context): String {
    val info =
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
            .getRunningServices(Int.MAX_VALUE)
            .firstOrNull { it.service.className == TunnelService::class.java.name }
            ?: return "no record"

    return "started=${info.started}, clients=${info.clientCount}, foreground=${info.foreground}"
}
