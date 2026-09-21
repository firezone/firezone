// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.tunnel.FakeDisconnectError
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.TunnelNotification
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.broadcastBootCompleted
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.revokeVpnConsent
import dev.firezone.android.tunnel.stopTunnelService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import uniffi.connlib.Event
import java.util.concurrent.TimeUnit
import javax.inject.Inject

// The one entry point with no screen behind it: the system's boot broadcast reaching the manifest
// receiver, which has only a notification to fall back on when it cannot connect.
@HiltAndroidTest
class BootE2eTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @Inject
    lateinit var repo: Repository

    @Inject
    internal lateinit var tokenStore: TokenStore

    @Inject
    lateinit var preferences: SharedPreferences

    @Before
    fun setUp() {
        hiltRule.inject()
        grantVpnConsent()
        grantNotificationPermission()
        FakeSessionFactory.reset()
        finishAllActivities()
        stopTunnelService()
        notificationManager().cancelAll()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun aStoredTokenConnectsOnBootWhenConfigured() {
        tokenStore.save(TOKEN)
        configureStartOnLogin(true)

        broadcastBootCompleted()

        val session = awaitSession()
        assertEquals(TOKEN, session.config.token)
        assertTrue(TunnelService.isRunning(context))
    }

    @Test
    fun nothingConnectsOnBootUnlessConfigured() {
        tokenStore.save(TOKEN)
        configureStartOnLogin(false)

        broadcastBootCompleted()

        assertNeverWithin("a session was opened") { FakeSessionFactory.opened > 0 }
        assertFalse(TunnelService.isRunning(context))
    }

    @Test
    fun aBootWithoutConsentAsksForItInANotification() {
        tokenStore.save(TOKEN)
        configureStartOnLogin(true)
        revokeVpnConsent()

        broadcastBootCompleted()

        assertEquals(
            "Firezone is no longer allowed to set up a VPN on this device. Open Firezone to grant the permission again.",
            awaitErrorNotification(),
        )
        assertEquals("a session was opened without consent", 0, FakeSessionFactory.opened)
    }

    // Nobody asked for this tunnel, so nobody is told when it goes away.
    @Test
    fun aBootStartedTunnelDisconnectsWithoutNotifying() {
        tokenStore.save(TOKEN)
        configureStartOnLogin(true)

        broadcastBootCompleted()
        val session = awaitSession()

        session.emit(Event.Disconnected(FakeDisconnectError(signInRequired = false, text = "the portal hung up")))

        // The notification, if any, is posted before the service stops itself.
        await("the tunnel service to stop") { !TunnelService.isRunning(context) }
        assertNull(notificationText(TunnelNotification.DISCONNECTED_NOTIFICATION_ID))
    }

    private fun configureStartOnLogin(startOnLogin: Boolean) {
        runBlocking { repo.saveSettings(repo.getConfigSync().copy(startOnLogin = startOnLogin)).first() }
    }

    private fun awaitSession(): FakeSession = runBlocking { withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() } }

    private fun awaitErrorNotification(): String? {
        await("the error notification") { notificationText(TunnelNotification.ERROR_NOTIFICATION_ID) != null }

        return notificationText(TunnelNotification.ERROR_NOTIFICATION_ID)
    }

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

    // A negative only has a deadline to go on. The receiver's own work is a preference read and a
    // service start, so a couple of seconds is well past it.
    private fun assertNeverWithin(
        what: String,
        condition: () -> Boolean,
    ) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(QUIET_MS)

        while (System.nanoTime() < deadline) {
            if (condition()) {
                throw AssertionError(what)
            }

            Thread.sleep(50)
        }
    }

    private fun notificationText(id: Int): String? =
        notificationManager()
            .activeNotifications
            .firstOrNull { it.id == id }
            ?.notification
            ?.extras
            ?.getString(Notification.EXTRA_TEXT)

    private fun notificationManager(): NotificationManager = context.getSystemService(NotificationManager::class.java)

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private companion object {
        const val TOKEN = "stored-token"
        const val TIMEOUT_MS = 20_000L
        const val QUIET_MS = 2_000L
    }
}
