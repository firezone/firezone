// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.tunnel.ACCOUNT_SLUG
import dev.firezone.android.tunnel.ACTOR_NAME
import dev.firezone.android.tunnel.FakeDisconnectError
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.TunnelNotification
import dev.firezone.android.tunnel.benchController
import dev.firezone.android.tunnel.engineeringWiki
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.internetResource
import dev.firezone.android.tunnel.launchApp
import dev.firezone.android.tunnel.resumedActivity
import dev.firezone.android.tunnel.startTunnelService
import dev.firezone.android.tunnel.stopTunnelService
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
import java.util.concurrent.TimeUnit
import javax.inject.Inject

// End-to-end through the real app, entered the way a user enters it: the launcher activity, the
// splash screen's own routing and the real `TunnelService`. The only thing standing in for
// production is connlib. What the fake session emits has to come out on screen, and what the
// screen does has to reach the fake session.
@HiltAndroidTest
class TunnelE2eTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeRule = createEmptyComposeRule()

    @Inject
    lateinit var repo: Repository

    @Inject
    internal lateinit var tokenStore: TokenStore

    @Inject
    lateinit var preferences: SharedPreferences

    @Inject
    internal lateinit var managedConfigurationSource: ManagedConfigurationSource

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
        notificationManager().cancelAll()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
        refreshManagedConfiguration()
    }

    @Test
    fun resourcesReachTheScreen() {
        val session = signInAndConnect()

        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(engineeringWiki),
                connectedDevices = emptyList(),
            ),
        )
        launchApp()

        awaitText("Engineering wiki")
        composeRule.onNodeWithText("wiki.example.com").assertIsDisplayed()
    }

    @Test
    fun connectedDevicesReachTheScreen() {
        val session = signInAndConnect()

        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(engineeringWiki),
                connectedDevices = listOf(benchController),
            ),
        )
        launchApp()

        awaitText("bench-controller-01")
        composeRule.onNodeWithText("Connected Devices").assertIsDisplayed()
    }

    @Test
    fun signingInReachesTheProfileMenuAndTheStoredAccount() {
        val session = signInAndConnect()

        session.emit(Event.ConnectedToPortal(accountSlug = ACCOUNT_SLUG, actorName = ACTOR_NAME))
        launchApp()

        // The top bar shows the initial; the name itself is behind the menu.
        awaitText("J")
        composeRule.onNodeWithText("J").performClick()
        awaitText(ACTOR_NAME)

        await("the account slug to be stored") { repo.getConfigSync().accountSlug == ACCOUNT_SLUG }
    }

    @Test
    fun aResourceUpdateAfterTheScreenIsOpenReachesIt() {
        val session = signInAndConnect()
        launchApp()
        awaitSessionScreen()

        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(engineeringWiki),
                connectedDevices = emptyList(),
            ),
        )

        awaitText("Engineering wiki")
    }

    @Test
    fun enablingTheInternetResourceReachesConnlib() {
        val session = signInAndConnect()

        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(internetResource),
                connectedDevices = emptyList(),
            ),
        )
        launchApp()

        awaitText("Internet Resource", substring = true)
        composeRule.onNodeWithText("Internet Resource", substring = true).performClick()
        awaitText("Enable this resource")
        composeRule.onNodeWithText("Enable this resource").performClick()

        runBlocking { withTimeout(TIMEOUT_MS) { session.awaitCommand("setInternetResourceState=true") } }
    }

    @Test
    fun aDisconnectErrorReturnsToTheSignInScreenAndNotifies() {
        val session = signInAndConnect()
        launchApp()
        awaitSessionScreen()

        session.emit(Event.Disconnected(FakeDisconnectError(signInRequired = false, text = "the portal hung up")))

        awaitSignInScreen()
        assertEquals("the portal hung up", awaitDisconnectedNotification())
        // The token is still good, so the disconnect must not have discarded it.
        assertEquals(TOKEN, tokenStore.get())
    }

    @Test
    fun aDisconnectErrorThatRequiresSigningInAgainDiscardsToken() {
        val session = signInAndConnect()
        launchApp()
        awaitSessionScreen()

        session.emit(Event.Disconnected(FakeDisconnectError(signInRequired = true, text = "your session expired")))

        awaitSignInScreen()
        assertEquals("your session expired", awaitDisconnectedNotification())
        assertNull(tokenStore.get())
    }

    @Test
    fun signingOutDiscardsToken() {
        val session = signInAndConnect()
        session.emit(Event.ConnectedToPortal(accountSlug = ACCOUNT_SLUG, actorName = ACTOR_NAME))
        launchApp()

        awaitText("J")
        composeRule.onNodeWithText("J").performClick()
        awaitText("Sign Out")
        composeRule.onNodeWithText("Sign Out").performClick()

        await("the token to be cleared") { tokenStore.get() == null }
        assertNull(tokenStore.get())
    }

    @Test
    fun aConnlibThatRefusesToStartLeavesTheUserOnTheSignInScreen() {
        FakeSessionFactory.failWith = { ConnlibException(NoHandle) }
        signIn()

        startTunnelService()
        launchApp()

        awaitSignInScreen()
    }

    @Test
    fun aManagedTokenAndDeviceNameReachConnlib() {
        signIn()
        TestRestrictions.bundle.putString("token", "managed-token")
        TestRestrictions.bundle.putString("deviceName", "Managed Pixel")
        refreshManagedConfiguration()

        startTunnelService()
        val session = awaitSession()

        assertEquals("managed-token", session.config.token)
        assertEquals("Managed Pixel", session.config.deviceName)
    }

    @Test
    fun managedTokenUpdatesReconnectAndRevocationRestoresTheSavedToken() {
        signIn()
        TestRestrictions.bundle.putString("token", "first-managed-token")
        refreshManagedConfiguration()
        startTunnelService()

        val firstSession = awaitSession()
        assertEquals("first-managed-token", firstSession.config.token)

        TestRestrictions.bundle.putString("token", "second-managed-token")
        refreshManagedConfiguration()
        runBlocking { withTimeout(TIMEOUT_MS) { firstSession.awaitCommand("disconnect") } }

        val secondSession = awaitSession()
        assertEquals("second-managed-token", secondSession.config.token)

        TestRestrictions.bundle.remove("token")
        refreshManagedConfiguration()
        runBlocking { withTimeout(TIMEOUT_MS) { secondSession.awaitCommand("disconnect") } }

        val restoredSession = awaitSession()
        assertEquals(TOKEN, restoredSession.config.token)
        assertEquals(TOKEN, tokenStore.get())
    }

    @Test
    fun managedAuthenticationFailurePreservesTheSavedUserToken() {
        signIn()
        TestRestrictions.bundle.putString("token", "managed-token")
        refreshManagedConfiguration()
        startTunnelService()

        val session = awaitSession()
        assertEquals("managed-token", session.config.token)
        session.emit(Event.Disconnected(FakeDisconnectError(signInRequired = true, text = "managed session expired")))

        assertEquals("managed session expired", awaitDisconnectedNotification())
        assertEquals(TOKEN, tokenStore.get())
    }

    private fun signInAndConnect(): FakeSession {
        signIn()
        startTunnelService()

        return awaitSession()
    }

    private fun signIn() = tokenStore.save(TOKEN)

    private fun refreshManagedConfiguration() = runBlocking { managedConfigurationSource.refresh() }

    private fun awaitSession(): FakeSession = runBlocking { withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() } }

    private fun awaitSessionScreen() = awaitText("Resources")

    private fun awaitSignInScreen() = awaitText("Sign in to access Resources.")

    private fun awaitText(
        text: String,
        substring: Boolean = false,
    ) = await("\"$text\" on screen") {
        // The splash screen is a View, so there are moments with no Compose content at all, which
        // `fetchSemanticsNodes` reports as an error rather than as an empty screen.
        runCatching {
            composeRule.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty()
        }.getOrDefault(false)
    }

    private fun awaitDisconnectedNotification(): String? {
        await("the disconnected notification") { disconnectedNotification() != null }

        return disconnectedNotification()
    }

    private fun await(
        what: String,
        condition: () -> Boolean,
    ) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS)

        while (!condition()) {
            if (System.nanoTime() > deadline) {
                throw AssertionError("Timed out waiting for $what, showing ${resumedActivity()}")
            }

            Thread.sleep(50)
        }
    }

    private fun disconnectedNotification(): String? =
        notificationManager()
            .activeNotifications
            .firstOrNull { it.id == TunnelNotification.DISCONNECTED_NOTIFICATION_ID }
            ?.notification
            ?.extras
            ?.getString(Notification.EXTRA_TEXT)

    private fun notificationManager(): NotificationManager =
        ApplicationProvider
            .getApplicationContext<Context>()
            .getSystemService(NotificationManager::class.java)

    private companion object {
        const val TOKEN = "stored-token"
        const val TIMEOUT_MS = 20_000L
    }
}
