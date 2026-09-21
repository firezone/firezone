// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.content.Context
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.RequiresManagedDevice
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.x509.TestDpc
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.stopTunnelService
import dev.firezone.android.tunnel.tunInterface
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit
import javax.inject.Inject

// An always-on VPN is started and revoked by the system rather than by anything in the app, so
// the device owner in the managed suite is what drives these.
@RequiresManagedDevice
@HiltAndroidTest
class AlwaysOnVpnE2eTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @Inject
    internal lateinit var tokenStore: TokenStore

    @Inject
    lateinit var preferences: SharedPreferences

    @Before
    fun setUp() {
        hiltRule.inject()
        // An always-on VPN left behind would have the system start the service again as soon as
        // the next line stops it.
        TestDpc.setAlwaysOnVpn(null, lockdown = false)
        grantVpnConsent()
        grantNotificationPermission()
        FakeSessionFactory.reset()
        finishAllActivities()
        stopTunnelService()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @After
    fun tearDown() {
        TestDpc.setAlwaysOnVpn(null, lockdown = false)
    }

    @Test
    fun theSystemStartsTheTunnelOnceMadeAlwaysOn() {
        tokenStore.save(TOKEN)

        TestDpc.setAlwaysOnVpn(context.packageName, lockdown = false)

        val session = awaitSession()
        assertEquals(TOKEN, session.config.token)
        assertTrue(TunnelService.isRunning(context))
    }

    @Test
    fun clearingTheAlwaysOnVpnRevokesTheTunnel() {
        tokenStore.save(TOKEN)
        TestDpc.setAlwaysOnVpn(context.packageName, lockdown = false)
        val session = awaitSession()

        // The system only revokes an interface it has established for us.
        session.emit(tunInterface())
        awaitCommand(session, "setTun")

        TestDpc.setAlwaysOnVpn(null, lockdown = false)

        awaitCommand(session, "disconnect")
        await("the tunnel service to stop") { !TunnelService.isRunning(context) }
    }

    private fun awaitSession(): FakeSession = runBlocking { withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() } }

    private fun awaitCommand(
        session: FakeSession,
        command: String,
    ) = runBlocking { withTimeout(TIMEOUT_MS) { session.awaitCommand(command) } }

    private fun await(
        what: String,
        condition: () -> Boolean,
    ) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS)

        while (!condition()) {
            if (System.nanoTime() > deadline) {
                throw AssertionError("Timed out waiting for $what")
            }

            Thread.sleep(50)
        }
    }

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private companion object {
        const val TOKEN = "stored-token"
        const val TIMEOUT_MS = 20_000L
    }
}
