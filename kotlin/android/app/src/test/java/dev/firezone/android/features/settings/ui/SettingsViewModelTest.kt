// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.data.ManagedConfigurationReader
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class SettingsViewModelTest {
    private lateinit var sharedPreferences: SharedPreferences
    private lateinit var repository: Repository
    private lateinit var viewModel: SettingsViewModel

    @Before
    fun setUp() {
        sharedPreferences =
            RuntimeEnvironment
                .getApplication()
                .getSharedPreferences("settings-view-model-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        repository = Repository(RuntimeEnvironment.getApplication(), Dispatchers.Unconfined, sharedPreferences)
        val managedConfigurationSource =
            ManagedConfigurationSource(
                RuntimeEnvironment.getApplication(),
                ManagedConfigurationReader { Bundle() },
                repository,
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            )
        viewModel = SettingsViewModel(repository, managedConfigurationSource)
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

            viewModel.resetSettingsToDefaults()
            viewModel.onCancel()

            assertTrue(FAVORITE_ID in repository.favorites.value.inner)
            assertEquals("https://managed.example.com", viewModel.configStateFlow.value.authUrl)
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
    }
}
