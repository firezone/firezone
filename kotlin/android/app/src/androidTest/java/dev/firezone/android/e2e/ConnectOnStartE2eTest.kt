// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.awaitTextOnScreen
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.launchApp
import dev.firezone.android.tunnel.stopTunnelService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import javax.inject.Inject

// The splash screen connects on its own only on the launch that created it, so both tests enter
// through the launcher rather than starting the service themselves.
@HiltAndroidTest
class ConnectOnStartE2eTest {
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
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun aStoredTokenConnectsOnLaunch() {
        tokenStore.save(TOKEN)
        configureConnectOnStart(true)

        launchApp()

        val session = awaitSession()
        assertEquals(TOKEN, session.config.token)
        assertTrue(TunnelService.isRunning(InstrumentationRegistry.getInstrumentation().targetContext))
        awaitTextOnScreen("Resources")
    }

    @Test
    fun aStoredTokenWaitsOnTheSignInScreenUnlessConfigured() {
        tokenStore.save(TOKEN)
        configureConnectOnStart(false)

        launchApp()

        awaitTextOnScreen("Sign in to access Resources.")
        assertEquals("a session was opened", 0, FakeSessionFactory.opened)
        assertFalse(TunnelService.isRunning(InstrumentationRegistry.getInstrumentation().targetContext))
    }

    private fun configureConnectOnStart(connectOnStart: Boolean) {
        runBlocking { repo.saveSettings(repo.getConfigSync().copy(connectOnStart = connectOnStart)).first() }
    }

    private fun awaitSession(): FakeSession = runBlocking { withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() } }

    private companion object {
        const val TOKEN = "stored-token"
        const val TIMEOUT_MS = 20_000L
    }
}
