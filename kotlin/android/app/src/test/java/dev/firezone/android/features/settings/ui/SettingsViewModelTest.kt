// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.os.Looper
import androidx.lifecycle.SavedStateHandle
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config as RobolectricConfig

@RunWith(RobolectricTestRunner::class)
@RobolectricConfig(sdk = [34], application = Application::class)
class SettingsViewModelTest {
    private lateinit var sharedPreferences: SharedPreferences
    private lateinit var repository: Repository

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication<Application>()
        sharedPreferences = context.getSharedPreferences("settings-view-model-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, sharedPreferences)
    }

    @Test
    fun `restores an unsaved draft after recreation`() =
        runBlocking {
            repository.saveSettings(savedConfig).first()
            val savedState = SavedStateHandle()
            val viewModel = SettingsViewModel(repository, savedState)

            viewModel.onConfigChanged(draftConfig)

            val recreatedViewModel = SettingsViewModel(repository, savedState)
            assertEquals(draftConfig, recreatedViewModel.uiState.value.config)
            assertEquals(savedConfig, repository.getConfigSync())
        }

    @Test
    fun `cancel discards an unsaved draft`() =
        runBlocking {
            repository.saveSettings(savedConfig).first()
            val savedState = SavedStateHandle()
            val viewModel = SettingsViewModel(repository, savedState)
            viewModel.onConfigChanged(draftConfig)

            viewModel.onCancel()

            val recreatedViewModel = SettingsViewModel(repository, savedState)
            assertEquals(savedConfig, recreatedViewModel.uiState.value.config)
        }

    @Test
    fun `canceling a reset keeps favorites and managed values`() =
        runBlocking {
            repository.addFavoriteResource(FAVORITE_ID)
            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString("authUrl", "https://managed.example.com")
                    },
                ).first()
            val viewModel = SettingsViewModel(repository, SavedStateHandle())

            viewModel.resetSettingsToDefaults()
            viewModel.onCancel()

            assertTrue(FAVORITE_ID in repository.favorites.value.inner)
            assertEquals("https://managed.example.com", viewModel.uiState.value.config.authUrl)
        }

    @Test
    fun `saving a reset clears favorites`() {
        repository.addFavoriteResource(FAVORITE_ID)
        val viewModel = SettingsViewModel(repository, SavedStateHandle())

        viewModel.resetSettingsToDefaults()
        viewModel.onSaveSettingsCompleted()
        shadowOf(Looper.getMainLooper()).idle()

        assertTrue(
            repository.favorites.value.inner
                .isEmpty(),
        )
    }

    @Test
    fun `reset remains pending across recreation until save`() {
        repository.addFavoriteResource(FAVORITE_ID)
        val savedState = SavedStateHandle()
        val viewModel = SettingsViewModel(repository, savedState)

        viewModel.resetSettingsToDefaults()
        val recreatedViewModel = SettingsViewModel(repository, savedState)

        assertTrue(FAVORITE_ID in repository.favorites.value.inner)
        recreatedViewModel.onSaveSettingsCompleted()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(
            repository.favorites.value.inner
                .isEmpty(),
        )
    }

    private companion object {
        const val FAVORITE_ID = "favorite-resource"

        val savedConfig =
            Config(
                authUrl = "https://app.firezone.dev",
                apiUrl = "wss://api.firezone.dev",
                logFilter = "info",
                accountSlug = "saved",
                startOnLogin = false,
                connectOnStart = false,
            )

        val draftConfig =
            savedConfig.copy(
                accountSlug = "draft",
                connectOnStart = true,
            )
    }
}
