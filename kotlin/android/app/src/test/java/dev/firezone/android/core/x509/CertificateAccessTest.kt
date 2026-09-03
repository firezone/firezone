// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import dev.firezone.android.core.data.ManagedConfigurationReader
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.X509_CERTIFICATE_ALIAS_RESTRICTION
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.security.PrivateKey
import java.security.cert.X509Certificate

/** Pins which configured alias is checked before Android asks the user for access. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class CertificateAccessTest {
    private val keyChain = WithholdingKeyChain()
    private val restrictions = Bundle()
    private lateinit var repository: Repository
    private lateinit var certificateAccess: CertificateAccess

    @Before
    fun setUp() {
        val application: Application = RuntimeEnvironment.getApplication()
        val preferences = application.getSharedPreferences("certificate-access-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        restrictions.clear()
        repository = Repository(application, Dispatchers.Unconfined, preferences)
        val managedConfigurationSource =
            ManagedConfigurationSource(
                application,
                ManagedConfigurationReader { Bundle(restrictions) },
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
        certificateAccess =
            CertificateAccess(
                repository = repository,
                managedConfigurationSource = managedConfigurationSource,
                keyChain = keyChain,
                coroutineDispatcher = Dispatchers.Unconfined,
            )
    }

    @Test
    fun `no configured alias needs no selection`() {
        assertFalse(runBlocking { certificateAccess.needsSelection() })
        assertEquals(emptySet<String>(), keyChain.requestedAliases.toSet())
    }

    @Test
    fun `an alias the KeyChain withholds needs selection`() {
        repository.saveX509CertificateAliasSync("user-alias")

        assertTrue(runBlocking { certificateAccess.needsSelection() })
        assertEquals(listOf("user-alias"), keyChain.requestedAliases)
    }

    @Test
    fun `a blank managed alias turns certificate access off`() {
        restrictions.putString(X509_CERTIFICATE_ALIAS_RESTRICTION, "")
        repository.saveX509CertificateAliasSync("user-alias")

        assertFalse(runBlocking { certificateAccess.needsSelection() })
        assertEquals(emptySet<String>(), keyChain.requestedAliases.toSet())
    }

    @Test
    fun `a KeyChain read failure is left for the session`() {
        repository.saveX509CertificateAliasSync("user-alias")
        keyChain.readFailure = IllegalStateException("KeyChain service unavailable")

        assertFalse(runBlocking { certificateAccess.needsSelection() })
    }

    @Test
    fun `a managed alias overrides the user's selection`() {
        restrictions.putString(X509_CERTIFICATE_ALIAS_RESTRICTION, "managed-alias")
        repository.saveX509CertificateAliasSync("user-alias")

        runBlocking { certificateAccess.needsSelection() }

        assertEquals(setOf("managed-alias"), keyChain.requestedAliases.toSet())
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
    }
}
