// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.X509_CERTIFICATE_RESTRICTION
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.security.PrivateKey
import java.security.cert.X509Certificate

/** Pins when the device policy is asked for the certificate, and when the user is. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class CertificateAccessTest {
    private val keyChain = WithholdingKeyChain()
    private val restrictions = Bundle()
    private val repository =
        Repository(
            Dispatchers.Unconfined,
            RuntimeEnvironment
                .getApplication()
                .getSharedPreferences("certificate-access-test", Context.MODE_PRIVATE),
        )
    private val certificateAccess = CertificateAccess(repository, restrictions, keyChain)

    @Test
    fun `without a word from the administrator only the policy is asked`() {
        assertTrue(runBlocking { certificateAccess.needsDiscovery() })
        assertFalse(runBlocking { certificateAccess.needsSelection() })
        assertEquals(emptySet<String>(), keyChain.requestedAliases.toSet())
    }

    @Test
    fun `a required certificate nobody named yet is the user's to release`() {
        restrictions.putBoolean(X509_CERTIFICATE_RESTRICTION, true)

        assertTrue(runBlocking { certificateAccess.needsDiscovery() })
        assertTrue(runBlocking { certificateAccess.needsSelection() })
        assertEquals(emptySet<String>(), keyChain.requestedAliases.toSet())
    }

    @Test
    fun `a required certificate the KeyChain withholds is the user's to release`() {
        restrictions.putBoolean(X509_CERTIFICATE_RESTRICTION, true)
        repository.saveX509CertificateAliasSync("device-alias")

        assertTrue(runBlocking { certificateAccess.needsSelection() })
        assertEquals(listOf("device-alias"), keyChain.requestedAliases)
    }

    @Test
    fun `a withheld certificate nobody required is only the policy's to name`() {
        repository.saveX509CertificateAliasSync("device-alias")

        assertTrue(runBlocking { certificateAccess.needsDiscovery() })
        assertFalse(runBlocking { certificateAccess.needsSelection() })
    }

    @Test
    fun `certificates turned off ask nobody`() {
        restrictions.putBoolean(X509_CERTIFICATE_RESTRICTION, false)
        repository.saveX509CertificateAliasSync("device-alias")

        assertFalse(runBlocking { certificateAccess.needsDiscovery() })
        assertFalse(runBlocking { certificateAccess.needsSelection() })
        assertEquals(emptySet<String>(), keyChain.requestedAliases.toSet())
    }

    @Test
    fun `a KeyChain read failure is left for the session`() {
        restrictions.putBoolean(X509_CERTIFICATE_RESTRICTION, true)
        repository.saveX509CertificateAliasSync("device-alias")
        keyChain.readFailure = IllegalStateException("KeyChain service unavailable")

        assertFalse(runBlocking { certificateAccess.needsDiscovery() })
        assertFalse(runBlocking { certificateAccess.needsSelection() })
    }

    /** A KeyChain that holds nothing we may read, the way an unprovisioned device does. */
    private class WithholdingKeyChain : KeyChain {
        val requestedAliases = mutableListOf<String>()
        var readFailure: RuntimeException? = null

        override fun certificateChain(alias: String): List<X509Certificate>? {
            requestedAliases += alias
            readFailure?.let { throw it }

            return null
        }

        override fun privateKey(alias: String): PrivateKey? {
            error("checking certificate access must not open its private key")
        }

        override fun choosePrivateKeyAlias(
            activity: Activity,
            requestUri: Uri?,
            preselectedAlias: String?,
            onChosen: (String?) -> Unit,
        ): Unit = error("the chooser is an Activity affair, which this test never reaches")

        override fun policyAlias(
            activity: Activity,
            requestUri: Uri?,
            onAnswer: (String?) -> Unit,
        ): Unit = error("asking the policy is an Activity affair, which this test never reaches")
    }
}
