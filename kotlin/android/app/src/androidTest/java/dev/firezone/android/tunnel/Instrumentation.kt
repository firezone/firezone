// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.UiDevice
import dev.firezone.android.core.presentation.MainActivity
import java.io.File
import java.util.concurrent.TimeUnit

// The tunnel runs as a `systemExempted` foreground service, which the platform only lets an app
// start while it holds VPN consent. Without this the first `startForeground` throws and takes the
// whole instrumentation process with it.
fun grantVpnConsent() {
    shell("appops set ${packageName()} ACTIVATE_VPN allow")
}

// The framework watches this op and revokes a VPN whose consent is withdrawn, which is the only
// lever a test has on an interface the app has already established.
fun revokeVpnConsent() {
    shell("appops set ${packageName()} ACTIVATE_VPN deny")
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

// An activity the app hands off to is still in flight in `system_server` when `startActivity`
// returns, and Espresso's `intended` only drains the main looper before checking, so a test has to
// wait for the screen itself before asserting anything about how it got there.
fun awaitResumed(activity: Class<out Activity>) {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)

    while (!isResumed(activity)) {
        if (System.nanoTime() > deadline) {
            throw AssertionError("Timed out waiting for ${activity.simpleName} to be on screen, showing ${resumedActivity()}")
        }

        Thread.sleep(50)
    }
}

private fun isResumed(activity: Class<out Activity>): Boolean {
    var resumed = false

    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        resumed =
            ActivityLifecycleMonitorRegistry
                .getInstance()
                .getActivitiesInStage(Stage.RESUMED)
                .any { activity.isInstance(it) }
    }

    return resumed
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

// Photographs the display, system dialogs included, into the app's private files where
// `emulator-tests.sh` collects it. The status bar is pinned through SystemUI's demo mode for the
// duration, so a clock or a battery level does not make two pictures of the same screen differ.
fun photographScreen(name: String) {
    val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "screenshots")
    directory.mkdirs()

    shell("settings put global sysui_demo_allowed 1")
    shell("am broadcast -a com.android.systemui.demo -e command enter")
    shell("am broadcast -a com.android.systemui.demo -e command clock -e hhmm 1200")
    shell("am broadcast -a com.android.systemui.demo -e command battery -e plugged false -e level 100")
    shell("am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e fully true")
    shell("am broadcast -a com.android.systemui.demo -e command network -e mobile hide")
    shell("am broadcast -a com.android.systemui.demo -e command notifications -e visible false")
    shell("am broadcast -a com.android.systemui.demo -e command status -e volume hide -e bluetooth hide")

    try {
        // The broadcasts land asynchronously, and the status bar redraws after them.
        Thread.sleep(1_000)

        if (!UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).takeScreenshot(File(directory, "$name.png"))) {
            throw AssertionError("Could not photograph the screen for $name")
        }
    } finally {
        shell("am broadcast -a com.android.systemui.demo -e command exit")
    }
}

private fun packageName() = InstrumentationRegistry.getInstrumentation().targetContext.packageName

// `executeShellCommand` does not run a shell: it splits the line on whitespace and executes that,
// so quotes, pipes, redirects and `VAR=value` prefixes reach the program as literal arguments.
fun shellOutput(command: String): String = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).executeShellCommand(command)

private fun shell(command: String) {
    shellOutput(command)
}

@Suppress("DEPRECATION")
private fun describeTunnelService(context: Context): String {
    val info =
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
            .getRunningServices(Int.MAX_VALUE)
            .firstOrNull { it.service.className == TunnelService::class.java.name }
            ?: return "no record"

    return "started=${info.started}, clients=${info.clientCount}, foreground=${info.foreground}, " +
        "bound by ${boundBy()}"
}

// `clientCount` says how many bindings hold the service open but not whose, and an established
// VPN is bound by the framework itself rather than by anything a test can finish.
private fun boundBy(): String =
    shellOutput("dumpsys activity services ${packageName()}")
        .lines()
        .filter { it.contains("Connection") }
        .joinToString("; ") { it.trim() }
        .ifEmpty { "nothing the dump names" }
