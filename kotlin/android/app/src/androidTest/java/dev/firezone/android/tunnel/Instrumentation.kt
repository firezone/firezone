// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.UserHandle
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import dev.firezone.android.core.BootReceiver
import dev.firezone.android.core.presentation.MainActivity
import java.io.File
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

// Back to the state of a fresh install, where `VpnService.prepare` hands out the consent dialog.
fun revokeVpnConsent() {
    shell("appops set ${packageName()} ACTIVATE_VPN default")
}

// `pm revoke` kills the process it takes a runtime permission from, and that process is the test.
// The platform keeps one door open for tests, behind permissions only the shell holds.
fun revokeNotificationPermission() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext

    instrumentation.uiAutomation.adoptShellPermissionIdentity(
        "android.permission.REVOKE_RUNTIME_PERMISSIONS",
        "android.permission.REVOKE_POST_NOTIFICATIONS_WITHOUT_KILL",
    )

    try {
        val userId = UserHandle::class.java.getMethod("myUserId").invoke(null) as Int

        Class
            .forName("android.permission.PermissionManager")
            .getMethod("revokePostNotificationPermissionWithoutKillForTest", String::class.java, Int::class.javaPrimitiveType)
            .invoke(context.getSystemService("permission"), context.packageName, userId)
    } finally {
        instrumentation.uiAutomation.dropShellPermissionIdentity()
    }

    // Once the user has answered the dialog, the system answers for them from then on.
    shell("pm clear-permission-flags ${packageName()} android.permission.POST_NOTIFICATIONS user-set user-fixed")
}

// What the system sends once per boot. The shell may send protected broadcasts, so this reaches
// the receiver the way the real one does, through the manifest.
fun broadcastBootCompleted() {
    shell("am broadcast -a ${Intent.ACTION_BOOT_COMPLETED} -n ${packageName()}/${BootReceiver::class.java.name}")
}

// The same entry point the splash screen uses, so `startedByUser` is set
// the way it is in production.
fun startTunnelService() {
    TunnelService.start(InstrumentationRegistry.getInstrumentation().targetContext, TunnelService.StartSource.CONNECT_ON_START)
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

// Reads the accessibility tree rather than Compose's own test rule. The rule waits for the
// composition to go idle and has no deadline of its own, and idleness is driven by frames, so an
// emulator that stops producing them leaves the wait with nothing to end it.
fun awaitTextOnScreen(
    text: String,
    substring: Boolean = false,
) {
    val found =
        UiDevice
            .getInstance(InstrumentationRegistry.getInstrumentation())
            .wait(Until.hasObject(selector(text, substring)), TimeUnit.SECONDS.toMillis(20))

    if (found != true) {
        throw AssertionError("Timed out waiting for \"$text\" on screen, showing ${resumedActivity()}")
    }
}

/** Taps whatever carries [text], once it is there. */
fun clickTextOnScreen(
    text: String,
    substring: Boolean = false,
) {
    awaitTextOnScreen(text, substring)

    UiDevice
        .getInstance(InstrumentationRegistry.getInstrumentation())
        .findObject(selector(text, substring))
        ?.click()
        ?: throw AssertionError("\"$text\" left the screen before it could be tapped")
}

/** Whether [text] is on screen now, for asserting that something is absent. */
fun isTextOnScreen(
    text: String,
    substring: Boolean = false,
): Boolean = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).hasObject(selector(text, substring))

private fun selector(
    text: String,
    substring: Boolean,
) = if (substring) By.textContains(text) else By.text(text)

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
