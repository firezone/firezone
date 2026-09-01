// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.X509_CERTIFICATE_ALIAS_RESTRICTION
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
import uniffi.x509claims.Identity
import java.security.PrivateKey
import java.security.cert.X509Certificate

/**
 * The routing half of the sign-in decision matrix: which alias is read and what a withheld or
 * missing certificate decides. What a present certificate claims is parsed by native code, so
 * those rows live in the instrumented `X509SignInE2eTest`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class CertificateUserTest {
    private val keyChain = WithholdingKeyChain()
    private val restrictions = Bundle()
    private val repository =
        Repository(
            RuntimeEnvironment.getApplication(),
            Dispatchers.Unconfined,
            RuntimeEnvironment
                .getApplication()
                .getSharedPreferences("certificate-user-test", Context.MODE_PRIVATE),
        )
    private val certificateUser = CertificateUser(repository, restrictions, X509Identity(keyChain))

    @Test
    fun `no configured alias needs no selection and claims nobody`() {
        assertFalse(runBlocking { certificateUser.needsSelection() })
        assertEquals(Identity.Absent, runBlocking { certificateUser.identity() })
        assertEquals(emptySet<String>(), keyChain.requestedAliases.toSet())
    }

    @Test
    fun `an alias the KeyChain withholds needs selection`() {
        repository.saveX509CertificateAliasSync("user-alias")

        assertTrue(runBlocking { certificateUser.needsSelection() })
    }

    @Test
    fun `a withheld certificate claims nobody`() {
        repository.saveX509CertificateAliasSync("user-alias")

        assertEquals(Identity.Absent, runBlocking { certificateUser.identity() })
    }

    @Test
    fun `a blank managed alias turns certificate authentication off`() {
        restrictions.putString(X509_CERTIFICATE_ALIAS_RESTRICTION, "")
        repository.saveX509CertificateAliasSync("user-alias")

        assertFalse(runBlocking { certificateUser.needsSelection() })
        assertEquals(emptySet<String>(), keyChain.requestedAliases.toSet())
    }

    @Test
    fun `a managed alias overrides the user's selection`() {
        restrictions.putString(X509_CERTIFICATE_ALIAS_RESTRICTION, "managed-alias")
        repository.saveX509CertificateAliasSync("user-alias")

        runBlocking { certificateUser.needsSelection() }

        assertEquals(setOf("managed-alias"), keyChain.requestedAliases.toSet())
    }

    /** A KeyChain that holds nothing we may read, the way an unprovisioned device does. */
    private class WithholdingKeyChain : KeyChain {
        val requestedAliases = mutableListOf<String>()

        override fun certificateChain(alias: String): List<X509Certificate>? {
            requestedAliases += alias

            return null
        }

        override fun privateKey(alias: String): PrivateKey? {
            requestedAliases += alias

            return null
        }

        override fun choosePrivateKeyAlias(
            activity: Activity,
            requestUri: Uri?,
            preselectedAlias: String?,
            onChosen: (String?) -> Unit,
        ): Unit = error("the chooser is an Activity affair, which this test never reaches")
    }
}
