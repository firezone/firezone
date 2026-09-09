// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.content.SharedPreferences
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.tunnel.ACCOUNT_SLUG
import dev.firezone.android.tunnel.ACTOR_NAME
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.engineeringWiki
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.shellOutput
import dev.firezone.android.tunnel.startTunnelService
import dev.firezone.android.tunnel.stopTunnelService
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import uniffi.connlib.Event
import java.util.concurrent.TimeUnit
import javax.inject.Inject

// End-to-end the way an operator runs the CLI: the wrapper script on the device, the app's own
// APK under `app_process`, and a binder hop into whatever the tunnel is currently doing.
@HiltAndroidTest
class CliE2eTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @Inject
    internal lateinit var tokenStore: TokenStore

    @Inject
    lateinit var preferences: SharedPreferences

    @Before
    fun setUp() {
        hiltRule.inject()
        grantVpnConsent()
        grantNotificationPermission()
        // Order matters: ending the last test's sessions lets its service finish, and finishing
        // its activities releases the binding that would otherwise keep the service alive.
        FakeSessionFactory.reset()
        finishAllActivities()
        stopTunnelService()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun statusReachesTheShell() {
        tokenStore.save(TOKEN)
        startTunnelService()

        val session = runBlocking { withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() } }

        session.emit(Event.ConnectedToPortal(accountSlug = ACCOUNT_SLUG, actorName = ACTOR_NAME))
        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(engineeringWiki),
                connectedDevices = emptyList(),
            ),
        )

        val status = awaitStatus("the resource to reach the CLI") { it.contains("Engineering wiki") }

        assertTrue(status, status.contains("Tunnel: UP"))
        assertTrue(status, status.contains("Signed in as: $ACTOR_NAME"))
    }

    @Test
    fun statusReportsTheTunnelIsDownWhenItIsNotRunning() {
        assertEquals("Tunnel: DOWN", status().trim())
    }

    private fun awaitStatus(
        what: String,
        condition: (String) -> Boolean,
    ): String {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS)

        while (true) {
            val status = status()

            if (condition(status)) {
                return status
            }

            if (System.nanoTime() > deadline) {
                throw AssertionError("Timed out waiting for $what, the CLI last said:\n$status")
            }

            Thread.sleep(500)
        }
    }

    // A single token, because `shellOutput` tokenizes rather than running a shell. Everything the
    // CLI needs a shell for lives in the wrapper script instead.
    private fun status(): String {
        val output =
            try {
                shellOutput("$CLI status")
            } catch (e: Exception) {
                throw AssertionError("Could not run $CLI. $PUSHED_BY", e)
            }

        if (output.isBlank()) {
            throw AssertionError("$CLI printed nothing. $PUSHED_BY")
        }

        return output
    }

    private companion object {
        const val TOKEN = "stored-token"
        const val TIMEOUT_MS = 20_000L
        const val CLI = "/data/local/tmp/firezone"
        const val PUSHED_BY = "kotlin/android/mise-tasks/emulator-tests.sh pushes it, so run the suite through that."
    }
}
