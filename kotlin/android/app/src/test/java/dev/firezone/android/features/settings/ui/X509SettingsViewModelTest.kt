// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.data.ManagedConfigurationReader
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.X509_CERTIFICATE_ALIAS_RESTRICTION
import dev.firezone.android.core.x509.KeyChain
import dev.firezone.android.core.x509.X509Identity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.security.PrivateKey
import java.security.cert.X509Certificate

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class X509SettingsViewModelTest {
    private val restrictions = Bundle()
    private lateinit var repository: Repository
    private lateinit var source: ManagedConfigurationSource
    private lateinit var viewModel: X509SettingsViewModel

    @Before
    fun setUp() {
        val application: Application = RuntimeEnvironment.getApplication()
        val preferences = application.getSharedPreferences("x509-settings-view-model-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        restrictions.clear()
        repository = Repository(application, Dispatchers.Unconfined, preferences)
        source =
            ManagedConfigurationSource(
                application,
                ManagedConfigurationReader { Bundle(restrictions) },
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
        viewModel = X509SettingsViewModel(repository, source, X509Identity(WithholdingKeyChain()))
    }

    @Test
    fun `live managed alias changes disable and restore the user selection`() {
        repository.saveX509CertificateAliasSync("user-alias")

        applyRestrictions(
            Bundle().apply {
                putString(X509_CERTIFICATE_ALIAS_RESTRICTION, "managed-alias")
            },
        )

        assertEquals("managed-alias", viewModel.uiStateFlow.value.alias)
        assertTrue(viewModel.uiStateFlow.value.isManaged)

        applyRestrictions(
            Bundle().apply {
                putString(X509_CERTIFICATE_ALIAS_RESTRICTION, "")
            },
        )

        assertNull(viewModel.uiStateFlow.value.alias)
        assertTrue(viewModel.uiStateFlow.value.isManaged)

        applyRestrictions(Bundle())

        assertEquals("user-alias", viewModel.uiStateFlow.value.alias)
        assertFalse(viewModel.uiStateFlow.value.isManaged)
    }

    @Test
    fun `managed alias cannot be replaced or forgotten by the settings screen`() {
        repository.saveX509CertificateAliasSync("user-alias")
        restrictions.putString(X509_CERTIFICATE_ALIAS_RESTRICTION, "managed-alias")
        applyRestrictions(Bundle(restrictions))

        viewModel.onAliasSelected("attempted-alias")
        drainMainLooper()
        viewModel.forgetSelection()
        drainMainLooper()

        assertEquals("user-alias", repository.getUserX509CertificateAliasSync())
        assertEquals("managed-alias", viewModel.uiStateFlow.value.alias)
        assertTrue(viewModel.uiStateFlow.value.isManaged)
    }

    @Test
    fun `unmanaged alias can be replaced and forgotten`() {
        applyRestrictions(Bundle())

        viewModel.onAliasSelected("selected-alias")
        drainMainLooper()
        assertEquals("selected-alias", repository.getUserX509CertificateAliasSync())

        viewModel.forgetSelection()
        drainMainLooper()
        assertNull(repository.getUserX509CertificateAliasSync())
    }

    private fun applyRestrictions(bundle: Bundle) {
        runBlocking { source.applyRestrictions(bundle) }
        drainMainLooper()
    }

    private fun drainMainLooper() {
        shadowOf(Looper.getMainLooper()).idle()
    }

    private class WithholdingKeyChain : KeyChain {
        override fun certificateChain(alias: String): List<X509Certificate>? = null

        override fun privateKey(alias: String): PrivateKey? = null

        override fun choosePrivateKeyAlias(
            activity: Activity,
            requestUri: Uri?,
            preselectedAlias: String?,
            onChosen: (String?) -> Unit,
        ): Unit = error("The settings ViewModel never opens the chooser itself")
    }
}
