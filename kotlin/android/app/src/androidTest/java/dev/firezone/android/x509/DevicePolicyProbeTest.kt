// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.x509

import android.content.Context
import android.content.RestrictionsManager
import android.security.KeyChain
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Asks whether the states an X.509-managed device can be in are reachable on a CI emulator.
 *
 * Provisioning happens before this runs: the workflow makes our own Device Policy Controller the
 * device owner and has it install two key pairs, granting only one of them. Installing a key pair
 * is an owner-only API that no `adb` command exposes, which is what a DPC is for.
 *
 * This is a probe, not coverage. It exists to find out whether the approach works at all.
 */
@RunWith(AndroidJUnit4::class)
class DevicePolicyProbeTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    /** The device this app authenticates from: an alias it may use yields a signing key. */
    @Test
    fun aGrantedAliasYieldsAPrivateKey() {
        assertNotNull(
            "The KeyChain gave up no private key for '$GRANTED'. " +
                "Either provisioning did not run or the grant did not take.",
            KeyChain.getPrivateKey(context, GRANTED),
        )

        assertNotNull(
            "The KeyChain gave up no certificate chain for '$GRANTED'.",
            KeyChain.getCertificateChain(context, GRANTED),
        )
    }

    /**
     * The personally-owned device carrying a work profile: the administrator installed the
     * identity but cannot release the key, so the app sees the alias as absent. This is the state
     * the certificate-selection screen exists for, and the one worth holding in place.
     */
    @Test
    fun anUngrantedAliasYieldsNothing() {
        assertNull(
            "The KeyChain handed over a private key for '$UNGRANTED', which was never granted. " +
                "The app's reason for showing the certificate screen would not hold.",
            KeyChain.getPrivateKey(context, UNGRANTED),
        )
    }

    /** Managed configuration is the other owner-only API the scripts drive by hand today. */
    @Test
    fun theOwnerCanPushManagedConfiguration() {
        val restrictions =
            (context.getSystemService(Context.RESTRICTIONS_SERVICE) as RestrictionsManager)
                .applicationRestrictions

        assertEquals(
            "Managed configuration did not reach the app; it holds ${restrictions.keySet()}.",
            GRANTED,
            restrictions.getString("x509CertificateAlias"),
        )
    }

    private companion object {
        const val GRANTED = "firezone-granted"
        const val UNGRANTED = "firezone-ungranted"
    }
}
