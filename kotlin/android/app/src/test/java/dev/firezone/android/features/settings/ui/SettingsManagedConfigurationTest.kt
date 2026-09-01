// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Looper
import androidx.lifecycle.SavedStateHandle
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Config
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
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config as RobolectricConfig
import javax.inject.Provider

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
        repository = Repository(Dispatchers.Unconfined, sharedPreferences)
        source =
            ManagedConfigurationSource(
                context,
                Provider { Bundle() },
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
        runBlocking { repository.saveUserConfig(userConfig) }
        viewModel = SettingsViewModel(repository, source, SavedStateHandle())
    }

    @Test
    fun `open settings follow managed configuration changes`() =
        runBlocking {
            repository.saveUserConfig(userConfig)

            source.applyRestrictions(
                Bundle().apply {
                    putString("authUrl", "https://managed.example.com")
                    putBoolean("connectOnStart", true)
                },
            )
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals("https://managed.example.com", viewModel.uiState.value.config.authUrl)
            assertTrue(viewModel.uiState.value.config.connectOnStart)
            assertTrue(viewModel.uiState.value.managedStatus.isAuthUrlManaged)
            assertTrue(viewModel.uiState.value.managedStatus.isConnectOnStartManaged)

            viewModel.onLogFilterChanged("trace")
            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals(userConfig.copy(logFilter = "trace"), viewModel.uiState.value.config)
            assertFalse(viewModel.uiState.value.managedStatus.isAuthUrlManaged)
            assertFalse(viewModel.uiState.value.managedStatus.isConnectOnStartManaged)
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
            assertEquals("https://managed.example.com", viewModel.uiState.value.config.authUrl)
        }

    @Test
    fun `managed field restores its unsaved user edit after revocation`() =
        runBlocking {
            repository.saveUserConfig(userConfig)
            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()
            val savedStateHandle = SavedStateHandle()
            val initialViewModel = SettingsViewModel(repository, source, savedStateHandle)

            initialViewModel.onAuthUrlChanged("https://unsaved.example.com")
            source.applyRestrictions(
                Bundle().apply {
                    putString("authUrl", "https://managed.example.com")
                },
            )
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("https://managed.example.com", initialViewModel.uiState.value.config.authUrl)

            val recreatedViewModel = SettingsViewModel(repository, source, savedStateHandle)

            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()

            recreatedViewModel.onLogFilterChanged("trace")
            assertEquals("https://unsaved.example.com", recreatedViewModel.uiState.value.config.authUrl)
            assertEquals("trace", recreatedViewModel.uiState.value.config.logFilter)

            recreatedViewModel.onSaveSettingsCompleted()
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(
                userConfig.copy(authUrl = "https://unsaved.example.com", logFilter = "trace"),
                repository.getUserConfigSync(),
            )
        }

    @Test
    fun `edit before the first managed snapshot updates the overlaid user draft`() =
        runBlocking {
            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString("authUrl", "https://managed.example.com")
                    },
                )
            val preSnapshotViewModel = SettingsViewModel(repository, source, SavedStateHandle())

            preSnapshotViewModel.onLogFilterChanged("trace")

            assertEquals("https://managed.example.com", preSnapshotViewModel.uiState.value.config.authUrl)
            assertEquals("trace", preSnapshotViewModel.uiState.value.config.logFilter)
        }

    @Test
    fun `saving after policy arrival preserves the prior user edit`() =
        runBlocking {
            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()
            viewModel.onAuthUrlChanged("https://unsaved.example.com")

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
            assertEquals("https://managed.example.com", viewModel.uiState.value.config.authUrl)

            source.applyRestrictions(Bundle())
            shadowOf(Looper.getMainLooper()).idle()
            viewModel.onLogFilterChanged("trace")
            viewModel.onSaveSettingsCompleted()
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals(userConfig.copy(logFilter = "trace"), repository.getUserConfigSync())
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
