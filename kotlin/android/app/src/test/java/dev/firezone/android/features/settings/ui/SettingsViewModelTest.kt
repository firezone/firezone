// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import androidx.lifecycle.SavedStateHandle
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config as RobolectricConfig

@RunWith(RobolectricTestRunner::class)
@RobolectricConfig(sdk = [34], application = Application::class)
class SettingsViewModelTest {
    private lateinit var repository: Repository

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication<Application>()
        val preferences = context.getSharedPreferences("settings-view-model-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        repository = Repository(context, Dispatchers.Unconfined, preferences)
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

    private companion object {
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
