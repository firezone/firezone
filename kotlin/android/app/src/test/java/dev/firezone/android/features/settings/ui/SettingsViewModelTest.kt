// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Portal
import dev.firezone.android.features.settings.ui.compose.SettingsPage
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
        viewModel.save(SettingsPage.GENERAL)
        shadowOf(Looper.getMainLooper()).idle()

        assertTrue(
            repository.favorites.value.inner
                .isEmpty(),
        )
    }

    @Test
    fun `saved US URLs show the US portal`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")

        populateFields()

        assertEquals(Portal.CLOUD_US, viewModel.portal)
    }

    @Test
    fun `saved self-hosted URLs show custom and keep the URLs`() {
        saveUrls("https://firezone.example.com", "wss://api.example.com")

        populateFields()

        assertEquals(Portal.CUSTOM, viewModel.portal)
        assertEquals("https://firezone.example.com", viewModel.config.authUrl)
        assertEquals("wss://api.example.com", viewModel.config.apiUrl)
    }

    @Test
    fun `picking the EU portal saves the EU URLs`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        populateFields()

        viewModel.onPortalChanged(Portal.CLOUD_EU)
        viewModel.save(SettingsPage.GENERAL)
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

            assertEquals(Portal.CUSTOM, viewModel.portal)
        }

    @Test
    fun `saved URLs with a trailing slash still show their portal`() {
        saveUrls("https://eu.app.firezone.dev/", "wss://eu.api.firezone.dev/")

        populateFields()

        assertEquals(Portal.CLOUD_EU, viewModel.portal)
    }

    @Test
    fun `picking custom keeps the URLs for editing`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        populateFields()

        viewModel.onPortalChanged(Portal.CUSTOM)
        viewModel.onValidateAuthUrl("https://firezone.example.com")
        viewModel.onValidateApiUrl("wss://api.firezone.example.com")
        viewModel.save(SettingsPage.GENERAL)
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(Portal.CUSTOM, viewModel.portal)
        assertEquals("https://firezone.example.com", repository.getConfigSync().authUrl)
        assertEquals("wss://api.firezone.example.com", repository.getConfigSync().apiUrl)
    }

    @Test
    fun `managed EU URLs show the EU portal`() =
        runBlocking {
            saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
            manageUrls("https://eu.app.firezone.dev/", "wss://eu.api.firezone.dev")

            populateFields()

            assertEquals(Portal.CLOUD_EU, viewModel.portal)
        }

    @Test
    fun `managed self-hosted URLs show custom`() =
        runBlocking {
            manageUrls("https://firezone.example.com", "wss://api.firezone.example.com")

            populateFields()

            assertEquals(Portal.CUSTOM, viewModel.portal)
            assertEquals("https://firezone.example.com", viewModel.config.authUrl)
        }

    @Test
    fun `saving keeps the log filter`() {
        populateFields()

        viewModel.onValidateLogFilter("debug")
        viewModel.save(SettingsPage.LOGS)
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals("debug", repository.getConfigSync().logFilter)
    }

    @Test
    fun `saving the settings page does not write the edited log filter`() {
        populateFields()
        val savedLogFilter = viewModel.config.logFilter

        viewModel.onValidateAccountSlug("example-corp")
        viewModel.onValidateLogFilter("firezone=trace")
        save()

        assertEquals("example-corp", repository.getConfigSync().accountSlug)
        assertEquals(savedLogFilter, repository.getConfigSync().logFilter)
        assertEquals(SettingsViewModel.ViewAction.NavigateBack, viewModel.actionStateFlow.value)
    }

    @Test
    fun `switching back to custom brings back the last saved custom URLs`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        populateFields()
        viewModel.onPortalChanged(Portal.CUSTOM)
        viewModel.onValidateAuthUrl("https://firezone.example.com")
        viewModel.onValidateApiUrl("wss://api.firezone.example.com")
        save()

        reopen()
        viewModel.onPortalChanged(Portal.CLOUD_EU)
        save()

        reopen()
        viewModel.onPortalChanged(Portal.CUSTOM)

        assertEquals("https://firezone.example.com", viewModel.config.authUrl)
        assertEquals("wss://api.firezone.example.com", viewModel.config.apiUrl)
    }

    @Test
    fun `switching to custom without saved custom URLs keeps the current ones`() {
        saveUrls("https://eu.app.firezone.dev", "wss://eu.api.firezone.dev")
        populateFields()

        viewModel.onPortalChanged(Portal.CUSTOM)

        assertEquals("https://eu.app.firezone.dev", viewModel.config.authUrl)
        assertEquals("wss://eu.api.firezone.dev", viewModel.config.apiUrl)
    }

    @Test
    fun `saving a cloud portal does not remember its URLs as custom`() {
        repository.saveLastCustomUrlsSync("https://firezone.example.com", "wss://api.firezone.example.com")
        populateFields()

        viewModel.onPortalChanged(Portal.CLOUD_US)
        save()

        assertEquals(
            "https://firezone.example.com" to "wss://api.firezone.example.com",
            repository.getLastCustomUrlsSync(),
        )
    }

    @Test
    fun `remembered custom URLs do not change the portal shown`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        repository.saveLastCustomUrlsSync("https://firezone.example.com", "wss://api.firezone.example.com")

        populateFields()

        assertEquals(Portal.CLOUD_US, viewModel.portal)
        assertEquals("https://app.firezone.dev", viewModel.config.authUrl)
    }

    @Test
    fun `managed custom URLs are not remembered`() =
        runBlocking {
            manageUrls("https://firezone.example.com", "wss://api.firezone.example.com")
            populateFields()

            save()

            assertEquals(null, repository.getLastCustomUrlsSync())
        }

    private fun save() {
        viewModel.save(SettingsPage.GENERAL)
        shadowOf(Looper.getMainLooper()).idle()
    }

    // What opening the settings screen again starts from.
    private fun reopen() {
        viewModel = SettingsViewModel(repository)
        populateFields()
    }

    private suspend fun manageUrls(
        authUrl: String,
        apiUrl: String,
    ) {
        repository
            .saveManagedConfiguration(
                Bundle().apply {
                    putString("authUrl", authUrl)
                    putString("apiUrl", apiUrl)
                },
            ).first()
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
