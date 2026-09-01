// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.content.SharedPreferences
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.X509_CERTIFICATE_ALIAS_RESTRICTION
import dev.firezone.android.core.x509.FakeKeyChain
import dev.firezone.android.core.x509.TestIdentity
import dev.firezone.android.core.x509.testIdentity
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.launchApp
import dev.firezone.android.tunnel.resumedActivity
import dev.firezone.android.tunnel.startTunnelService
import dev.firezone.android.tunnel.stopTunnelService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit
import javax.inject.Inject

/**
 * The sign-in decision matrix, walked the way a user walks it: what the configured certificate
 * claims decides whether the app connects outright, sends the user to the browser, or asks for
 * the certificate first. Only the portal is stood in for, by the scripted session factory; the
 * claims are read by the real parser out of certificates minted per test.
 */
@HiltAndroidTest
class X509SignInE2eTest {
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
        grantNotificationPermission()
        FakeSessionFactory.reset()
        FakeKeyChain.reset()
        finishAllActivities()
        stopTunnelService()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun aCertificateClaimingAnEmailConnectsWithoutABrowser() {
        val identity = testIdentity(SERIAL_CLAIM, EMAIL_CLAIM, ACCOUNT_CLAIM)
        givenTheUserPicked(identity)

        launchApp()

        awaitText("Connect as jane.doe@example.com")
        composeRule.onNodeWithText("Connect as jane.doe@example.com").performClick()

        val session = awaitSession()

        // The certificate is the credential: the one we configured goes out, no token does, and
        // no browser sign-in ever opens.
        assertArrayEquals(identity.chain.first().encoded, session.tlsIdentity?.certificateChain()?.first())
        assertNull(session.config.token)
        awaitText("Resources")
        assertFalse("a browser sign-in was opened", authActivityExists())
    }

    @Test
    fun aCertificateClaimingAnActorIdConnectsWithoutABrowser() {
        givenTheUserPicked(testIdentity(SERIAL_CLAIM, ACTOR_ID_CLAIM))

        launchApp()

        // An actor ID claims somebody without naming them, so the button has no email to offer.
        awaitText("Connect")
        composeRule.onNodeWithText("Connect").performClick()

        val session = awaitSession()

        assertNotNull(session.tlsIdentity)
        assertNull(session.config.token)
        awaitText("Resources")
        assertFalse("a browser sign-in was opened", authActivityExists())
    }

    @Test
    fun aDeviceOnlyCertificateSendsTheUserToTheBrowser() {
        givenTheUserPicked(testIdentity(SERIAL_CLAIM))

        launchApp()

        awaitText("Sign In")
        composeRule.onNodeWithText("Sign In").performClick()

        await("the browser sign-in to open") { authActivityExists() }
        assertEquals("a session was opened without a token", 0, FakeSessionFactory.opened)
    }

    @Test
    fun aDeviceOnlyCertificateConnectsWithCertificateAndToken() {
        givenTheUserPicked(testIdentity(SERIAL_CLAIM))
        runBlocking { repo.saveToken(TOKEN).first() }

        startTunnelService()
        val session = awaitSession()

        // The certificate attests the device and the token names the actor, so both go out.
        assertNotNull(session.tlsIdentity)
        assertEquals(TOKEN, session.config.token)
    }

    @Test
    fun aCarriedButInvalidIdentityClaimStillConnects() {
        givenTheUserPicked(testIdentity(SERIAL_CLAIM, INVALID_EMAIL_CLAIM))

        launchApp()

        // The claim is carried but not readable, so the button has no email to offer. Whether
        // to reject the claim is the portal's policy, so the certificate connects regardless.
        awaitText("Connect")
        composeRule.onNodeWithText("Connect").performClick()

        val session = awaitSession()

        assertNotNull(session.tlsIdentity)
        assertNull(session.config.token)
        awaitText("Resources")
        assertFalse("a browser sign-in was opened", authActivityExists())
    }

    @Test
    fun withoutACertificateTheBrowserIsTheOnlyWayIn() {
        launchApp()

        awaitText("Sign In")
        composeRule.onNodeWithText("Sign In").performClick()

        await("the browser sign-in to open") { authActivityExists() }
        assertEquals("a session was opened without any credential", 0, FakeSessionFactory.opened)
    }

    @Test
    fun aTokenAloneConnectsWithoutACertificate() {
        runBlocking { repo.saveToken(TOKEN).first() }

        startTunnelService()
        val session = awaitSession()

        assertNull(session.tlsIdentity)
        assertEquals(TOKEN, session.config.token)
    }

    @Test
    fun anUngrantedManagedCertificateRoutesToTheCertificateScreen() {
        FakeKeyChain.install(ALIAS, testIdentity(SERIAL_CLAIM, EMAIL_CLAIM, ACCOUNT_CLAIM), granted = false)
        TestRestrictions.bundle.putString(X509_CERTIFICATE_ALIAS_RESTRICTION, ALIAS)

        launchApp()

        awaitText("Select your client certificate")
    }

    /** Installs [identity] as granted and records its alias the way the settings screen would. */
    private fun givenTheUserPicked(identity: TestIdentity) {
        FakeKeyChain.install(ALIAS, identity, granted = true)
        repo.saveX509CertificateAliasSync(ALIAS)
    }

    private fun awaitSession(): FakeSession = runBlocking { withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() } }

    private fun authActivityExists(): Boolean {
        var exists = false

        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            exists =
                Stage
                    .values()
                    .filter { stage -> stage != Stage.DESTROYED }
                    .flatMap { stage -> ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(stage) }
                    .any { activity -> activity is AuthActivity }
        }

        return exists
    }

    private fun awaitText(text: String) =
        await("\"$text\" on screen") {
            // The splash screen is a View, so there are moments with no Compose content at all,
            // which `fetchSemanticsNodes` reports as an error rather than as an empty screen.
            runCatching {
                composeRule.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
            }.getOrDefault(false)
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

    private companion object {
        const val ALIAS = "firezone-e2e"
        const val TOKEN = "browser-token"
        const val TIMEOUT_MS = 20_000L

        const val SERIAL_CLAIM = "firezone://serial/EMU-4711"
        const val EMAIL_CLAIM = "firezone://email/jane.doe@example.com"
        const val INVALID_EMAIL_CLAIM = "firezone://email/jane.doe.example.com"
        const val ACCOUNT_CLAIM = "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
        const val ACTOR_ID_CLAIM = "firezone://actor-id/0b9a5e12-6f64-4a2f-8c2e-3d1f2a7b9c01"
    }
}
