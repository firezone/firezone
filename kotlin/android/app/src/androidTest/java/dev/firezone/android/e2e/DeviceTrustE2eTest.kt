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
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.data.X509_CERTIFICATE_RESTRICTION
import dev.firezone.android.core.x509.FakeKeyChain
import dev.firezone.android.core.x509.TestIdentity
import dev.firezone.android.core.x509.testIdentity
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.splash.ui.SplashViewModel
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.launchApp
import dev.firezone.android.tunnel.resumedActivity
import dev.firezone.android.tunnel.startTunnelService
import dev.firezone.android.tunnel.stopTunnelService
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit
import javax.inject.Inject

/**
 * Pins how the device certificate is found and combines with the portal token and Android's
 * KeyChain permission. Only the portal is stood in for, by the scripted session factory.
 */
@HiltAndroidTest
class DeviceTrustE2eTest {
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

    @Before
    fun setUp() {
        hiltRule.inject()
        grantVpnConsent()
        grantNotificationPermission()
        FakeSessionFactory.reset()
        FakeKeyChain.reset()
        SplashViewModel.policyAsked = false
        finishAllActivities()
        stopTunnelService()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun aCertificateWithoutATokenStillRequiresBrowserSignIn() {
        givenCertificate(testIdentity(SERIAL_CLAIM))

        launchApp()

        awaitText("Sign In")
        composeRule.onNodeWithText("Sign In").performClick()

        await("the browser sign-in to open") { authActivityExists() }
        assertEquals("a session was opened without a token", 0, FakeSessionFactory.opened)
    }

    @Test
    fun aDeviceCertificateAccompaniesThePortalToken() {
        val certificate = testIdentity(SERIAL_CLAIM)
        givenCertificate(certificate)
        tokenStore.save(TOKEN)

        startTunnelService()
        val session = awaitSession()

        assertArrayEquals(certificate.chain.first().encoded, session.tlsIdentity?.certificateChain()?.first())
        assertEquals(TOKEN, session.config.token)
    }

    @Test
    fun withoutACertificateTheBrowserIsTheOnlyWayIn() {
        launchApp()

        awaitText("Sign In")
        composeRule.onNodeWithText("Sign In").performClick()

        await("the browser sign-in to open") { authActivityExists() }
        assertEquals("a session was opened without any credential", 0, FakeSessionFactory.opened)
    }

    /**
     * Nobody required a certificate and the policy names none, so an installed one is left alone:
     * nothing is asked of the user and the session goes out without it.
     */
    @Test
    fun aTokenAloneConnectsWithoutACertificate() {
        FakeKeyChain.install(ALIAS, testIdentity(SERIAL_CLAIM), granted = false)
        tokenStore.save(TOKEN)

        launchApp()

        awaitText("Sign In")

        startTunnelService()
        val session = awaitSession()

        assertNull(session.tlsIdentity)
        assertEquals(TOKEN, session.config.token)
    }

    /**
     * The zero-touch case: the administrator's policy answers the KeyChain for us, so the
     * certificate is used without a word in the managed configuration and nothing asked of the user.
     */
    @Test
    fun aPolicyAnswerNeedsNoConfigurationAndNoUser() {
        val certificate = testIdentity(SERIAL_CLAIM)
        FakeKeyChain.install(ALIAS, certificate, granted = true)
        FakeKeyChain.policyAnswers(ALIAS)
        tokenStore.save(TOKEN)

        launchApp()

        awaitText("Sign In")

        startTunnelService()
        val session = awaitSession()

        assertArrayEquals(certificate.chain.first().encoded, session.tlsIdentity?.certificateChain()?.first())
    }

    /**
     * A required certificate the policy does not hand over is the user's to release, which is how a
     * work profile on a personally-owned device presents. The screen offers no way around it.
     */
    @Test
    fun aRequiredCertificateTheKeyChainWithholdsRoutesToDeviceTrust() {
        FakeKeyChain.install(ALIAS, testIdentity(SERIAL_CLAIM), granted = false)
        TestRestrictions.bundle.putBoolean(X509_CERTIFICATE_RESTRICTION, true)

        launchApp()

        awaitText("Select your client certificate")
        assertTrue("the required certificate can be skipped", composeRule.onAllNodesWithText("Skip").fetchSemanticsNodes().isEmpty())
    }

    @Test
    fun theReleasedCertificateIsRememberedAndPresented() {
        val certificate = testIdentity(SERIAL_CLAIM)
        FakeKeyChain.install(ALIAS, certificate, granted = false)
        FakeKeyChain.userChooses(ALIAS)
        TestRestrictions.bundle.putBoolean(X509_CERTIFICATE_RESTRICTION, true)
        tokenStore.save(TOKEN)

        launchApp()

        awaitText("Select your client certificate")
        composeRule.onNodeWithText("Select certificate").performClick()

        awaitText("Sign In")

        startTunnelService()
        val session = awaitSession()

        assertArrayEquals(certificate.chain.first().encoded, session.tlsIdentity?.certificateChain()?.first())
    }

    /**
     * Android grants whatever the user picks in the chooser, but only a certificate carrying the
     * device certificate's common name is the administrator's, so any other is refused.
     */
    @Test
    fun pickingACertificateThatIsNotADeviceCertificateIsRefused() {
        FakeKeyChain.install(OTHER_ALIAS, testIdentity(SERIAL_CLAIM, commonName = "mail.example.com"), granted = false)
        FakeKeyChain.userChooses(OTHER_ALIAS)
        TestRestrictions.bundle.putBoolean(X509_CERTIFICATE_RESTRICTION, true)

        launchApp()

        awaitText("Select your client certificate")
        composeRule.onNodeWithText("Select certificate").performClick()

        awaitText("'$OTHER_ALIAS' is not a Firezone device certificate.", substring = true)
        awaitText("Select your client certificate")
        assertNull(repo.getX509CertificateAliasSync(TestRestrictions.bundle))
    }

    /** A required certificate is not to be degraded past: without it there is no session. */
    @Test
    fun aRequiredCertificateStopsTheTunnelUntilReleased() {
        FakeKeyChain.install(ALIAS, testIdentity(SERIAL_CLAIM), granted = false)
        TestRestrictions.bundle.putBoolean(X509_CERTIFICATE_RESTRICTION, true)
        tokenStore.save(TOKEN)

        startTunnelService()

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        await("the tunnel to give up") { !TunnelService.isRunning(context) }
        assertEquals("a session was opened without the required certificate", 0, FakeSessionFactory.opened)
    }

    /** Installs [certificate] as granted and records its alias the way discovery would. */
    private fun givenCertificate(certificate: TestIdentity) {
        FakeKeyChain.install(ALIAS, certificate, granted = true)
        TestRestrictions.bundle.putBoolean(X509_CERTIFICATE_RESTRICTION, true)
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

    private fun awaitText(
        text: String,
        substring: Boolean = false,
    ) = await("\"$text\" on screen") {
        // The splash screen is a View, so there are moments with no Compose content at all,
        // which `fetchSemanticsNodes` reports as an error rather than as an empty screen.
        runCatching {
            composeRule.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty()
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
        const val OTHER_ALIAS = "mail-e2e"
        const val TOKEN = "browser-token"
        const val TIMEOUT_MS = 20_000L

        const val SERIAL_CLAIM = "firezone://serial/EMU-4711"
    }
}
