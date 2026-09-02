// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.data.ManagedConfigurationReader
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config as RobolectricConfig

@RunWith(RobolectricTestRunner::class)
@RobolectricConfig(application = Application::class)
class SettingsManagedConfigurationTest {
    private lateinit var repository: Repository
    private lateinit var source: ManagedConfigurationSource
    private lateinit var viewModel: SettingsViewModel

    @Before
    fun setUp() {
        val context: Application = RuntimeEnvironment.getApplication()
        val sharedPreferences =
            context.getSharedPreferences("settings-managed-configuration-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, sharedPreferences)
        source =
            ManagedConfigurationSource(
                context,
                ManagedConfigurationReader { Bundle() },
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
        runBlocking { repository.saveSettings(userConfig).first() }
        viewModel = SettingsViewModel(repository, source)
    }

    @Test
    fun `open settings follow managed configuration changes`() =
        runBlocking {
            repository.saveSettings(userConfig).first()

            source.applyRestrictions(
                Bundle().apply {
                    putString("authUrl", "https://managed.example.com")
                    putBoolean("connectOnStart", true)
                },
            )
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals("https://managed.example.com", viewModel.configStateFlow.value.authUrl)
            assertTrue(viewModel.configStateFlow.value.connectOnStart)
            assertTrue(viewModel.managedStatusStateFlow.value!!.isAuthUrlManaged)
            assertTrue(viewModel.managedStatusStateFlow.value!!.isConnectOnStartManaged)

            viewModel.onValidateLogFilter("trace")
            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals(userConfig.copy(logFilter = "trace"), viewModel.configStateFlow.value)
            assertFalse(viewModel.managedStatusStateFlow.value!!.isAuthUrlManaged)
            assertFalse(viewModel.managedStatusStateFlow.value!!.isConnectOnStartManaged)
        }

    @Test
    fun `device trust availability follows the managed alias overlay`() =
        runBlocking {
            repository.saveX509CertificateAliasSync("user-alias")

            source.applyRestrictions(
                Bundle().apply {
                    putString("x509CertificateAlias", "")
                },
            )
            assertFalse(viewModel.hasConfiguredCertificateAlias())

            source.applyRestrictions(Bundle())
            assertTrue(viewModel.hasConfiguredCertificateAlias())

            repository.saveX509CertificateAliasSync(null)
            assertFalse(viewModel.hasConfiguredCertificateAlias())
        }

    @Test
    fun `canceling a reset keeps favorites and managed values`() =
        runBlocking {
            repository.addFavoriteResource(FAVORITE_ID)
            source.applyRestrictions(
                Bundle().apply {
                    putString("authUrl", "https://managed.example.com")
                },
            )
            shadowOf(Looper.getMainLooper()).idle()

            viewModel.resetSettingsToDefaults()
            viewModel.onCancel()

            assertTrue(FAVORITE_ID in repository.favorites.value.inner)
            assertEquals("https://managed.example.com", viewModel.configStateFlow.value.authUrl)
        }

    @Test
    fun `managed field restores its unsaved user edit after revocation`() =
        runBlocking {
            repository.saveSettings(userConfig).first()
            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()

            viewModel.onValidateAuthUrl("https://unsaved.example.com")
            source.applyRestrictions(
                Bundle().apply {
                    putString("authUrl", "https://managed.example.com")
                },
            )
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("https://managed.example.com", viewModel.configStateFlow.value.authUrl)

            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals("https://unsaved.example.com", viewModel.configStateFlow.value.authUrl)
        }

    @Test
    fun `edit before the first managed snapshot updates the overlaid user draft`() =
        runBlocking {
            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString("authUrl", "https://managed.example.com")
                    },
                ).first()
            val preSnapshotViewModel = SettingsViewModel(repository, source)

            preSnapshotViewModel.onValidateLogFilter("trace")

            assertEquals("https://managed.example.com", preSnapshotViewModel.configStateFlow.value.authUrl)
            assertEquals("trace", preSnapshotViewModel.configStateFlow.value.logFilter)
        }

    @Test
    fun `saving after policy arrival preserves the prior user edit`() =
        runBlocking {
            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()
            viewModel.onValidateAuthUrl("https://unsaved.example.com")

            source.applyRestrictions(
                Bundle().apply {
                    putString("authUrl", "https://managed.example.com")
                },
            )
            shadowOf(Looper.getMainLooper()).idle()
            viewModel.onSaveSettingsCompleted()
            shadowOf(Looper.getMainLooper()).idle()

            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals("https://unsaved.example.com", repository.getConfigSync().authUrl)
        }

    @Test
    fun `editing another field after policy removal preserves the raw user value`() =
        runBlocking {
            source.applyRestrictions(
                Bundle().apply {
                    putString("authUrl", "https://managed.example.com")
                },
            )
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("https://managed.example.com", viewModel.configStateFlow.value.authUrl)

            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()
            viewModel.onValidateLogFilter("trace")
            viewModel.onSaveSettingsCompleted()
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals(userConfig.copy(logFilter = "trace"), repository.getUserConfigSync())
        }

    @Test
    fun `sequential field callbacks preserve earlier draft edits`() =
        runBlocking {
            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()

            viewModel.onValidateAuthUrl("https://edited.example.com")
            viewModel.onValidateLogFilter("trace")
            viewModel.onConnectOnStartChanged(true)

            assertEquals(
                userConfig.copy(
                    authUrl = "https://edited.example.com",
                    logFilter = "trace",
                    connectOnStart = true,
                ),
                viewModel.configStateFlow.value,
            )
        }

    @Test
    fun `saving a reset clears favorites`() {
        repository.addFavoriteResource(FAVORITE_ID)

        viewModel.resetSettingsToDefaults()
        viewModel.onSaveSettingsCompleted()
        shadowOf(Looper.getMainLooper()).idle()

        assertTrue(
            repository.favorites.value.inner
                .isEmpty(),
        )
    }

    private companion object {
        const val FAVORITE_ID = "favorite-resource"

        val userConfig =
            Config(
                authUrl = "https://user.example.com",
                apiUrl = "wss://user.example.com",
                logFilter = "info",
                accountSlug = "user-account",
                startOnLogin = false,
                connectOnStart = false,
            )
    }
}
