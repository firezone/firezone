// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.UiDevice
import dev.firezone.android.core.presentation.MainActivity
import java.util.concurrent.TimeUnit

// The tunnel runs as a `systemExempted` foreground service, which the platform only lets an app
// start while it holds VPN consent. Without this the first `startForeground` throws and takes the
// whole instrumentation process with it.
fun grantVpnConsent() {
    shell("appops set ${packageName()} ACTIVATE_VPN allow")
}

// Without it the splash screen sends the app to the permission prompt instead of the session, and
// nothing the tunnel posts on disconnect ever reaches the shade.
fun grantNotificationPermission() {
    shell("pm grant ${packageName()} android.permission.POST_NOTIFICATIONS")
}

// The same entry point the splash screen and the boot receiver use, so `startedByUser` is set
// the way it is in production.
fun startTunnelService() {
    TunnelService.start(InstrumentationRegistry.getInstrumentation().targetContext)
}

// Enters through the launcher, so that the splash screen's own routing decides which screen the
// test ends up on.
fun launchApp() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext

    context.startActivity(
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
    )
}

// The app spans several activities and the test only starts the first, so it cannot clean up by
// handle. Whatever is left standing would otherwise show the previous test's screen to the next.
fun finishAllActivities() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)

    while (true) {
        var remaining = emptyList<String>()

        instrumentation.runOnMainSync {
            val activities =
                Stage
                    .values()
                    .filter { it != Stage.DESTROYED }
                    .flatMap { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(it) }

            remaining = activities.map { it::class.java.simpleName }
            activities.forEach { it.finish() }
        }

        if (remaining.isEmpty()) {
            return
        }

        if (System.nanoTime() > deadline) {
            throw AssertionError("Activities are still up: $remaining")
        }

        Thread.sleep(50)
    }
}

// Names what the user would be looking at, which is what tells a screen that has not arrived yet
// apart from an app that has closed.
fun resumedActivity(): String {
    var name = "nothing"

    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        name =
            ActivityLifecycleMonitorRegistry
                .getInstance()
                .getActivitiesInStage(Stage.RESUMED)
                .joinToString { it::class.java.simpleName }
                .ifEmpty { "nothing" }
    }

    return name
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

private fun packageName() = InstrumentationRegistry.getInstrumentation().targetContext.packageName

private fun shell(command: String) {
    UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).executeShellCommand(command)
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
