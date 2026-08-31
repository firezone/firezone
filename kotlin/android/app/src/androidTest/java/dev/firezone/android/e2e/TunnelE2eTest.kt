// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.content.SharedPreferences
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.core.data.Repository
import dev.firezone.android.features.session.ui.SessionActivity
import dev.firezone.android.tunnel.FakeDisconnectError
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.connectedDevice
import dev.firezone.android.tunnel.dnsResource
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.internetResource
import dev.firezone.android.tunnel.startTunnelService
import dev.firezone.android.tunnel.stopTunnelService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import uniffi.connlib.ConnlibException
import uniffi.connlib.Event
import uniffi.connlib.NoHandle
import javax.inject.Inject

// End-to-end through the real app: a signed-in device starts the real `TunnelService`, and the
// only thing standing in for production is connlib itself. What the fake session emits has to
// come out the other end on screen, and what the screen does has to reach the fake session.
@HiltAndroidTest
class TunnelE2eTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeRule = createEmptyComposeRule()

    @Inject
    lateinit var repo: Repository

    @Inject
    lateinit var preferences: SharedPreferences

    @Before
    fun setUp() {
        hiltRule.inject()
        grantVpnConsent()
        // Ending the last test's sessions first is what lets its service finish and stop.
        FakeSessionFactory.reset()
        stopTunnelService()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun resourcesReachTheScreen() {
        val session = signInAndConnect()

        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(dnsResource(name = "GitLab")),
                connectedDevices = emptyList(),
            ),
        )

        onSessionScreen {
            awaitText("GitLab")
            composeRule.onNodeWithText("gitlab.example.com").assertIsDisplayed()
        }
    }

    @Test
    fun connectedDevicesReachTheScreen() {
        val session = signInAndConnect()

        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(dnsResource(name = "GitLab")),
                connectedDevices = listOf(connectedDevice(name = "Ada's Laptop")),
            ),
        )

        onSessionScreen {
            awaitText("Ada's Laptop")
            composeRule.onNodeWithText("Connected Devices").assertIsDisplayed()
        }
    }

    @Test
    fun theActorNameReachesTheProfileMenu() {
        val session = signInAndConnect()

        session.emit(Event.ConnectedToPortal(accountSlug = "acme", actorName = "Ada Lovelace"))

        onSessionScreen {
            // The top bar shows the initial; the name itself is behind the menu.
            awaitText("A")
            composeRule.onNodeWithText("A").performClick()
            awaitText("Ada Lovelace")
        }
    }

    @Test
    fun aResourceUpdateAfterTheScreenIsOpenReachesIt() {
        val session = signInAndConnect()

        onSessionScreen {
            session.emit(
                Event.ResourcesUpdated(
                    resources = listOf(dnsResource(name = "GitLab")),
                    connectedDevices = emptyList(),
                ),
            )
            awaitText("GitLab")
        }
    }

    @Test
    fun enablingTheInternetResourceReachesConnlib() {
        val session = signInAndConnect()

        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(internetResource()),
                connectedDevices = emptyList(),
            ),
        )

        onSessionScreen {
            awaitText("Internet Resource", substring = true)
            composeRule.onNodeWithText("Internet Resource", substring = true).performClick()
            awaitText("Enable this resource")
            composeRule.onNodeWithText("Enable this resource").performClick()

            runBlocking {
                withTimeout(TIMEOUT_MS) { session.awaitCommand("setInternetResourceState=true") }
            }
        }
    }

    @Test
    fun aShutdownClosesTheScreen() {
        val session = signInAndConnect()

        ActivityScenario.launch(SessionActivity::class.java).use { scenario ->
            composeRule.waitUntil(TIMEOUT_MS) { scenario.state == Lifecycle.State.RESUMED }

            session.emit(Event.Disconnected(FakeDisconnectError(signInRequired = false)))

            composeRule.waitUntil(TIMEOUT_MS) { scenario.state == Lifecycle.State.DESTROYED }
            assertEquals(TOKEN, repo.getTokenSync())
        }
    }

    @Test
    fun aShutdownThatRequiresSigningInAgainDiscardsTheToken() {
        val session = signInAndConnect()

        ActivityScenario.launch(SessionActivity::class.java).use { scenario ->
            composeRule.waitUntil(TIMEOUT_MS) { scenario.state == Lifecycle.State.RESUMED }

            session.emit(Event.Disconnected(FakeDisconnectError(signInRequired = true)))

            composeRule.waitUntil(TIMEOUT_MS) { scenario.state == Lifecycle.State.DESTROYED }
            assertNull(repo.getTokenSync())
        }
    }

    @Test
    fun aConnlibThatRefusesToStartClosesTheScreen() {
        FakeSessionFactory.failWith = { ConnlibException(NoHandle) }
        signIn()
        startTunnelService()

        ActivityScenario.launch(SessionActivity::class.java).use { scenario ->
            composeRule.waitUntil(TIMEOUT_MS) { scenario.state == Lifecycle.State.DESTROYED }
        }
    }

    @Test
    fun aManagedTokenAndDeviceNameReachConnlib() {
        signIn()
        TestRestrictions.bundle.putString("token", "managed-token")
        TestRestrictions.bundle.putString("deviceName", "Managed Pixel")

        startTunnelService()
        val session = awaitSession()

        assertEquals("managed-token", session.config.token)
        assertEquals("Managed Pixel", session.config.deviceName)
    }

    private fun signInAndConnect(): FakeSession {
        signIn()
        startTunnelService()

        return awaitSession()
    }

    private fun signIn() = runBlocking { repo.saveToken(TOKEN).first() }

    private fun awaitSession(): FakeSession = runBlocking { withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() } }

    private fun onSessionScreen(block: () -> Unit) {
        ActivityScenario.launch(SessionActivity::class.java).use { block() }
    }

    private fun awaitText(
        text: String,
        substring: Boolean = false,
    ) {
        composeRule.waitUntil(TIMEOUT_MS) {
            composeRule.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private companion object {
        const val TOKEN = "stored-token"
        const val TIMEOUT_MS = 20_000L
    }
}
