// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.RequiresManagedDevice
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.launchApp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import javax.inject.Inject

/**
 * Pins what the real KeyChain answers in each state the DPC can put it in, which is the contract
 * `X509Identity` reads into its errors and every fake standing in for the KeyChain has to keep.
 */
@RequiresManagedDevice
@HiltAndroidTest
class ManagedKeyChainTest {
    @get:Rule
    val hiltRule = HiltAndroidRule(this)

    @Inject
    lateinit var preferences: SharedPreferences

    private val systemKeyChain = SystemKeyChain(ApplicationProvider.getApplicationContext<Context>())

    @Before
    fun setUp() {
        hiltRule.inject()
        grantNotificationPermission()
        finishAllActivities()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun anInstalledButUngrantedAliasIsWithheld() {
        val identity = testIdentity("firezone://serial/EMU-UNGRANTED")

        TestDpc.installKeyPair(UNGRANTED_ALIAS, identity.pkcs12(UNGRANTED_ALIAS, PASSWORD), PASSWORD, grantToFirezone = false)

        assertNull(systemKeyChain.privateKey(UNGRANTED_ALIAS))
        assertNull(systemKeyChain.certificateChain(UNGRANTED_ALIAS))
    }

    @Test
    fun aGrantedAliasHandsOverTheKeyAndTheFullChain() {
        val identity = testIdentity("firezone://serial/EMU-GRANTED")

        TestDpc.installKeyPair(GRANTED_ALIAS, identity.pkcs12(GRANTED_ALIAS, PASSWORD), PASSWORD, grantToFirezone = true)

        val chain = systemKeyChain.certificateChain(GRANTED_ALIAS)
        val privateKey = systemKeyChain.privateKey(GRANTED_ALIAS)

        assertEquals(identity.chain, chain)
        assertNotNull(privateKey)

        // The key never leaves the keystore, so what matters is that it signs: every scheme the
        // identity offers is one connlib may pick at the handshake.
        val tlsIdentity = KeyChainTlsIdentity(GRANTED_ALIAS, chain!!, privateKey!!)

        for (scheme in tlsIdentity.supportedSignatureSchemes()) {
            val signature = tlsIdentity.sign(scheme, MESSAGE)
            val verified =
                KeyChainTlsIdentity.signature(scheme).run {
                    initVerify(identity.chain.first().publicKey)
                    update(MESSAGE)
                    verify(signature)
                }

            assertTrue("$scheme should verify", verified)
        }
    }

    @Test
    fun anAliasWithNothingBehindItLooksWithheldToo() {
        assertNull(systemKeyChain.privateKey(EMPTY_ALIAS))
        assertNull(systemKeyChain.certificateChain(EMPTY_ALIAS))

        // Which is why the loader phrases the two states as one problem.
        val exception =
            assertThrows(X509IdentityException::class.java) {
                X509Identity(systemKeyChain).load(EMPTY_ALIAS)
            }

        assertTrue(
            "unexpected message: ${exception.message}",
            exception.message!!.contains("has not been granted access"),
        )
    }

    @Test
    fun choosingTheCertificateGrantsTheConfiguredAlias() {
        val identity = testIdentity("firezone://serial/EMU-CHOOSER")

        TestDpc.installKeyPair(CHOOSER_ALIAS, identity.pkcs12(CHOOSER_ALIAS, PASSWORD), PASSWORD, grantToFirezone = false)

        assertNull(systemKeyChain.privateKey(CHOOSER_ALIAS))

        launchApp()

        val chosen = CompletableFuture<String?>()
        systemKeyChain.choosePrivateKeyAlias(resumedActivity(), null, CHOOSER_ALIAS) { alias ->
            chosen.complete(alias)
        }

        approveKeyChainChooser(CHOOSER_ALIAS)

        assertEquals(CHOOSER_ALIAS, chosen.get(TIMEOUT_MS, TimeUnit.MILLISECONDS))

        // The KeyChain remembers the grant, so from here the alias reads like a granted one.
        assertNotNull(systemKeyChain.privateKey(CHOOSER_ALIAS))
        assertNotNull(systemKeyChain.certificateChain(CHOOSER_ALIAS))
    }

    @Test
    fun anOfferedAliasTheKeyChainDoesNotHoldStillLetsTheUserChoose() {
        val identity = testIdentity("firezone://serial/EMU-MISNAMED")

        TestDpc.installKeyPair(MISNAMED_ALIAS, identity.pkcs12(MISNAMED_ALIAS, PASSWORD), PASSWORD, grantToFirezone = false)

        launchApp()

        val chosen = CompletableFuture<String?>()
        systemKeyChain.choosePrivateKeyAlias(resumedActivity(), null, EMPTY_ALIAS) { alias ->
            chosen.complete(alias)
        }

        approveKeyChainChooser(MISNAMED_ALIAS)

        // The offered alias is a pre-selection only: the chooser lists what is installed regardless
        // and grants whichever the user picks.
        assertEquals(MISNAMED_ALIAS, chosen.get(TIMEOUT_MS, TimeUnit.MILLISECONDS))
        assertNotNull(systemKeyChain.privateKey(MISNAMED_ALIAS))
        assertNotNull(systemKeyChain.certificateChain(MISNAMED_ALIAS))
    }

    /** Confirms the system chooser with [alias] selected, whether or not it arrived preselected. */
    private fun approveKeyChainChooser(alias: String) {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

        if (!device.wait(Until.hasObject(By.pkg("com.android.keychain")), TIMEOUT_MS)) {
            throw AssertionError("The KeyChain chooser never appeared")
        }

        // Every row names its alias, which tells the certificates the other tests installed apart.
        val row =
            device.wait(Until.findObject(By.text(alias)), TIMEOUT_MS)
                ?: throw AssertionError("The KeyChain chooser does not list '$alias'")

        row.click()

        val confirm =
            device.wait(Until.findObject(By.res("android:id/button1")), TIMEOUT_MS)
                ?: throw AssertionError("The KeyChain chooser offers nothing to confirm")

        confirm.click()
    }

    private fun resumedActivity(): Activity {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS)

        while (true) {
            var activity: Activity? = null

            instrumentation.runOnMainSync {
                activity =
                    ActivityLifecycleMonitorRegistry
                        .getInstance()
                        .getActivitiesInStage(Stage.RESUMED)
                        .firstOrNull()
            }

            activity?.let {
                return it
            }

            if (System.nanoTime() > deadline) {
                throw AssertionError("No activity reached the foreground")
            }

            Thread.sleep(50)
        }
    }

    private companion object {
        // One alias per test: a KeyChain grant is remembered per alias, so sharing one would
        // let a granted test decide what an ungranted one sees.
        const val UNGRANTED_ALIAS = "firezone-test-ungranted"
        const val GRANTED_ALIAS = "firezone-test-granted"
        const val EMPTY_ALIAS = "firezone-test-never-installed"
        const val CHOOSER_ALIAS = "firezone-test-chooser"
        const val MISNAMED_ALIAS = "firezone-test-misnamed"

        const val PASSWORD = "firezone"
        const val TIMEOUT_MS = 20_000L

        val MESSAGE = "a TLS handshake transcript".toByteArray()
    }
}
