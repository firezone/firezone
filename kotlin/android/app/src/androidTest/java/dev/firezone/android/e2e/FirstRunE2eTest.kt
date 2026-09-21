// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.VpnService
import androidx.core.content.ContextCompat
import androidx.test.espresso.intent.rule.IntentsRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.awaitTextOnScreen
import dev.firezone.android.tunnel.clickTextOnScreen
import dev.firezone.android.tunnel.engineeringWiki
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.launchApp
import dev.firezone.android.tunnel.revokeNotificationPermission
import dev.firezone.android.tunnel.revokeVpnConsent
import dev.firezone.android.tunnel.stopTunnelService
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import uniffi.connlib.Event
import javax.inject.Inject

// The screens a new user taps through on a fresh install, up to their first resource. Nothing is
// granted or stored up front, so the system's own consent dialogs are part of the path.
@HiltAndroidTest
class FirstRunE2eTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val intentsRule = IntentsRule()

    @Inject
    lateinit var repo: Repository

    @Inject
    internal lateinit var tokenStore: TokenStore

    @Inject
    lateinit var preferences: SharedPreferences

    @Before
    fun setUp() {
        hiltRule.inject()
        FakeSessionFactory.reset()
        finishAllActivities()
        stopTunnelService()
        revokeVpnConsent()
        revokeNotificationPermission()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun aNewUserIsWalkedFromPermissionsToTheirResources() {
        val attempt = stubAuthTab(Activity.RESULT_OK)

        launchApp()

        awaitTextOnScreen("Enable VPN Permission")
        clickTextOnScreen("Request Permission")
        confirmSystemDialog("com.android.vpndialogs", By.res("android:id/button1"))

        awaitTextOnScreen("Enable Notifications")
        assertNull("VPN consent was not granted", VpnService.prepare(context))
        clickTextOnScreen("Request Permission")
        confirmSystemDialog("com.android.permissioncontroller", By.res("com.android.permissioncontroller:id/permission_allow_button"))

        awaitTextOnScreen("Sign in to access Resources.")
        assertTrue(repo.hasRequestedNotificationPermission())
        assertEquals(
            PackageManager.PERMISSION_GRANTED,
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS),
        )
        clickTextOnScreen("Sign In")

        val session = awaitSession()
        assertEquals(checkNotNull(attempt.get()).token, tokenStore.get())
        assertEquals(1, FakeSessionFactory.opened)

        session.emit(
            Event.ResourcesUpdated(
                resources = listOf(engineeringWiki),
                connectedDevices = emptyList(),
            ),
        )

        awaitTextOnScreen("Engineering wiki")
    }

    private fun confirmSystemDialog(
        packageName: String,
        button: BySelector,
    ) {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

        if (!device.wait(Until.hasObject(By.pkg(packageName)), TIMEOUT_MS)) {
            throw AssertionError("The $packageName dialog never appeared")
        }

        val confirm =
            device.wait(Until.findObject(button), TIMEOUT_MS)
                ?: throw AssertionError("The $packageName dialog offers nothing to confirm")

        confirm.click()
    }

    private fun awaitSession(): FakeSession = runBlocking { withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() } }

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private companion object {
        const val TIMEOUT_MS = 20_000L
    }
}
