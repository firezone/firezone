// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.CloudRegion
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
        viewModel = SettingsViewModel(repository)
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
            assertEquals("https://managed.example.com", viewModel.config.authUrl)
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

    @Test
    fun `saved US URLs show the US region`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")

        populateFields()

        assertEquals(CloudRegion.US, viewModel.cloudRegion)
    }

    @Test
    fun `saved self-hosted URLs show custom and keep the URLs`() {
        saveUrls("https://firezone.example.com", "wss://api.example.com")

        populateFields()

        assertEquals(CloudRegion.CUSTOM, viewModel.cloudRegion)
        assertEquals("https://firezone.example.com", viewModel.config.authUrl)
        assertEquals("wss://api.example.com", viewModel.config.apiUrl)
    }

    @Test
    fun `picking the EU region saves the EU URLs`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        populateFields()

        viewModel.onCloudRegionChanged(CloudRegion.EU)
        viewModel.onSaveSettingsCompleted()
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals("https://eu.app.firezone.dev", repository.getConfigSync().authUrl)
        assertEquals("wss://eu.api.firezone.dev", repository.getConfigSync().apiUrl)
    }

    @Test
    fun `one managed URL shows custom`() =
        runBlocking {
            saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString("apiUrl", "wss://api.firezone.dev")
                    },
                ).first()

            populateFields()

            assertEquals(CloudRegion.CUSTOM, viewModel.cloudRegion)
        }

    private fun saveUrls(
        authUrl: String,
        apiUrl: String,
    ) {
        sharedPreferences
            .edit()
            .putString("authUrl", authUrl)
            .putString("apiUrl", apiUrl)
            .commit()
    }

    private fun populateFields() {
        viewModel.populateFieldsFromConfig()
        shadowOf(Looper.getMainLooper()).idle()
    }

    private companion object {
        const val FAVORITE_ID = "favorite-resource"
    }
}
